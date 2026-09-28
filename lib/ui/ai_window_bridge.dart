import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/ai_conversation_store.dart';
import '../data/ai_image.dart';
import '../data/terminal_ai.dart';
import '../domain/appearance.dart';
import 'ai_task_controller.dart';

/// Channel shared with the Windows runner (`harbor/ai_window`).
///
/// Main engine -> native: `open` (no arguments at all), `changed` (sanitized UI
/// mirror), `hide`. Child engine -> native: `state` (startup handshake),
/// `action`, `dock`. Native -> main engine: `closed`; native -> child engine:
/// `changed`. The native side only relays; every ownership and permission
/// decision stays in the main engine.
const aiWindowChannel = MethodChannel('harbor/ai_window');

/// Coalescing window for mirror pushes. Streaming turns notify per token, so an
/// unthrottled mirror would send one channel message per delta.
const aiWindowPushInterval = Duration(milliseconds: 120);

/// User actions the detached window forwards to the main engine.
abstract final class AiWindowOp {
  static const start = 'start';
  static const stop = 'stop';
  static const approve = 'approve';
  static const setModel = 'setModel';
  static const setApprovalMode = 'setApprovalMode';
  static const setAutoApprove = 'setAutoApprove';
  static const listModels = 'listModels';
  static const loadHistory = 'loadHistory';
  static const newConversation = 'newConversation';
  static const openConversation = 'openConversation';
  static const deleteConversation = 'deleteConversation';
  static const previewConversation = 'previewConversation';
  static const settings = 'settings';
}

/// Owns the AI controller of every SSH session and mirrors the one session that
/// is currently detached into the native window.
///
/// One controller stays the single owner of the SSH executor, the API client
/// and the encrypted conversation store; the second engine only renders and
/// forwards. `changed`/`state` payloads never carry an API key, an SSH secret
/// or command text typed outside the conversation.
class AiWindowHost {
  AiWindowHost({
    required this.appearance,
    this.pushInterval = aiWindowPushInterval,
  });

  /// Current appearance of the main window, mirrored so the detached window
  /// matches its theme.
  final AppearancePreferences Function() appearance;

  /// Delay used to coalesce mirror pushes. [Duration.zero] pushes eagerly.
  final Duration pushInterval;

  final _sessions = <String, _DetachedSession>{};
  String? _sessionId;
  bool _attached = false;

  /// Session mirrored by the detached window, or null when it is hidden.
  String? get openSessionId => _sessionId;

  /// Whether [sessionId] is the session currently shown in the detached window.
  bool isDetached(String sessionId) => _sessionId == sessionId;

  void attach() {
    if (_attached) return;
    _attached = true;
    aiWindowChannel.setMethodCallHandler(handle);
  }

  /// Takes ownership of [task] for [sessionId].
  ///
  /// The listener is installed once here and removed by [unregister] or
  /// [dispose]; opening and closing the window never re-subscribes. Registering
  /// the same session again (a reconnected pane) bumps the mirror generation so
  /// the detached window drops the previous conversation instead of mixing it.
  void register(
    String sessionId,
    AiTaskController task,
    String hostName, {
    required VoidCallback onDock,
    VoidCallback? onSettings,
  }) {
    final previous = _sessions.remove(sessionId);
    final session = _DetachedSession(
      this,
      sessionId,
      task,
      hostName,
      onDock,
      onSettings,
      (previous?.generation ?? 0) + 1,
    );
    _sessions[sessionId] = session;
    task.addListener(session.markDirty);
    previous?.detach();
    if (_sessionId == sessionId) session.rebuild();
  }

  /// Releases [sessionId]. A detached window is told that the session is gone
  /// and the native window is hidden; the task is never stopped here.
  void unregister(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    session.detach();
    if (_sessionId != sessionId) return;
    _sessionId = null;
    session.announceClosed();
  }

  /// Creates (or wakes) the single native AI window and mirrors [sessionId].
  ///
  /// No sensitive value crosses the channel or the process arguments. Check
  /// [isDetached] afterwards: a window that could not be created leaves the
  /// session embedded in the main window.
  Future<void> open(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final previous = _sessionId;
    _setSession(sessionId);
    // Entries are mirrored from scratch (the window may show another
    // conversation), but image bytes are content addressed and stay cached for
    // as long as the child engine lives: a wake-up never re-uploads them.
    session.reset(images: false);
    try {
      await aiWindowChannel.invokeMethod<void>('open');
    } catch (_) {
      // Keep the conversation that is actually on screen. A failed open must
      // not embed that pane while the native window is still showing it.
      if (_sessionId == sessionId) _sessionId = previous;
      return;
    }
    if (_sessionId != sessionId) return;
    // One native window shows one conversation. The pane that lost it embeds
    // its panel again; the task itself keeps running.
    if (previous != null && previous != sessionId) {
      _sessions[previous]?.reembed();
    }
    await session.flush();
  }

  /// Returns [sessionId] to the main window and hides the native window.
  ///
  /// The child engine hides itself when it asks to dock. This is the main
  /// window asking, so the hide is explicit. The task is never stopped.
  Future<void> dock(String sessionId) async {
    if (_sessionId != sessionId || _sessions[sessionId] == null) return;
    _setSession(null);
    _sessions[sessionId]!.reembed();
    await _invoke('hide');
  }

  /// Pushes one sanitized mirror right now (appearance change, text scale).
  void refresh() {
    final id = _sessionId;
    if (id == null) return;
    _sessions[id]?.markDirty(immediate: true);
  }

  void dispose() {
    for (final session in _sessions.values) {
      session.detach();
    }
    _sessions.clear();
    _sessionId = null;
    if (_attached) {
      aiWindowChannel.setMethodCallHandler(null);
      _attached = false;
    }
  }

  void _setSession(String? id) {
    if (_sessionId == id) return;
    // Mirror caches survive a switch: image bytes are content addressed and the
    // child engine keeps its cache, so returning to a session only resends the
    // entries. A child that restarts clears them through its `state` handshake.
    _sessionId = id;
  }

  /// Entry point of the native relay (also used by tests).
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'state':
        return _state(call.arguments);
      case 'action':
        return _action(call.arguments);
      case 'dock':
        return _dock(call.arguments);
      case 'closed':
        return _closed();
      default:
        throw MissingPluginException('Unknown AI window operation');
    }
  }

  Future<Object?> _state(Object? arguments) async {
    final map = arguments is Map ? arguments : const {};
    final requested = map['sessionId'];
    if (requested is String && _sessions.containsKey(requested)) {
      _setSession(requested);
    }
    final session = _sessionId == null ? null : _sessions[_sessionId];
    if (session == null) return const <String, Object?>{'sessionId': null};
    // A fresh child engine (or one that lost bytes) starts from a full mirror.
    if (map['ready'] == true || map['resync'] == true) session.reset();
    return session.snapshot(full: true);
  }

  Future<Object?> _action(Object? arguments) async {
    final map = arguments is Map ? arguments : const {};
    final requested = map['sessionId'];
    final session = _sessions[requested is String ? requested : _sessionId];
    if (session == null) {
      throw PlatformException(code: 'session', message: 'AI 会话已关闭，请从主窗口重新打开');
    }
    final op = map['op'];
    if (op is! String) {
      throw PlatformException(code: 'op', message: '无效的 AI 窗口操作');
    }
    final argumentsMap = map['args'] is Map
        ? Map<String, Object?>.from(map['args'] as Map)
        : const <String, Object?>{};
    final generation = session.generation;
    final result = await session.run(op, argumentsMap);
    // A reply that arrives after the window moved to another session (or after
    // its pane was rebuilt) must never drag the old conversation back.
    if (_sessionId == session.sessionId && session.generation == generation) {
      return <String, Object?>{
        'state': session.snapshot(full: false),
        'result': result,
      };
    }
    final current = _sessionId == null ? null : _sessions[_sessionId];
    return <String, Object?>{
      // The window may never have seen a base for this session, so the reply is
      // a full mirror instead of a patch.
      'state':
          current?.snapshot(full: true) ??
          const <String, Object?>{'sessionId': null},
      'result': result,
    };
  }

  Future<Object?> _dock(Object? arguments) async {
    final map = arguments is Map ? arguments : const {};
    final requested = map['sessionId'];
    final id = requested is String ? requested : _sessionId;
    if (id == null || _sessions[id] == null) return null;
    _setSession(null);
    // Native hides the window itself on a successful `dock`.
    _sessions[id]!.reembed();
    return null;
  }

  Future<Object?> _closed() async {
    final id = _sessionId;
    if (id == null) return null;
    // The native window was closed by the user (WM_CLOSE): the panel goes back
    // into the main window and the running task keeps running.
    _setSession(null);
    _sessions[id]?.reembed();
    return null;
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await aiWindowChannel.invokeMethod<void>(method, arguments);
    } catch (_) {
      // The window may already be gone; mirrors are best effort.
    }
  }
}

/// Per-session mirror bookkeeping on the main engine side.
class _DetachedSession {
  _DetachedSession(
    this.host,
    this.sessionId,
    this.task,
    this.hostName,
    this.onDock,
    this.onSettings,
    this.generation,
  );

  final AiWindowHost host;
  final String sessionId;
  final AiTaskController task;
  final String hostName;
  final VoidCallback onDock;
  final VoidCallback? onSettings;

  /// Bumped whenever a session id is re-registered with a new controller.
  final int generation;

  bool _disposed = false;
  bool _full = true;
  bool _dirty = false;
  Timer? _timer;
  final _sentEntries = <String>[];
  final _sentImages = <String>{};
  final _entryRefs = <_EntryRefs>[];

  bool get _mirrored => host.openSessionId == sessionId;

  void markDirty({bool immediate = false}) {
    if (_disposed || !_mirrored) return;
    _dirty = true;
    if (immediate || host.pushInterval <= Duration.zero) {
      _timer?.cancel();
      _timer = null;
      unawaited(flush());
      return;
    }
    _timer ??= Timer(host.pushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Sends the pending mirror, if any.
  Future<void> flush() async {
    if (_disposed || !_mirrored || !_dirty) return;
    _dirty = false;
    await host._invoke('changed', snapshot(full: false));
  }

  /// Forces the next mirror to carry every entry again.
  ///
  /// [images] additionally drops the record of delivered image bytes, which is
  /// only correct for a child engine that starts over (or lost its cache).
  void reset({bool images = true}) {
    _sentEntries.clear();
    if (images) _sentImages.clear();
    _full = true;
    _dirty = true;
    _timer?.cancel();
    _timer = null;
  }

  /// The pane was rebuilt behind an open window: mirror it from scratch.
  void rebuild() {
    reset(images: false);
    markDirty(immediate: true);
  }

  /// The session is gone: tell the window, then hide it.
  void announceClosed() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    unawaited(
      host._invoke('changed', <String, Object?>{
        'sessionId': sessionId,
        'generation': generation,
        'closed': true,
      }),
    );
    unawaited(host._invoke('hide'));
  }

  /// The window went away: the main window shows the panel again. Never stops
  /// the task and never disposes the controller.
  void reembed() => onDock();

  void detach() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    task.removeListener(markDirty);
  }

  /// Runs one forwarded user action against the owning controller.
  Future<Object?> run(String op, Map<String, Object?> arguments) async {
    final task = this.task;
    try {
      switch (op) {
        case AiWindowOp.start:
          await task.start(
            arguments['goal'] as String? ?? '',
            images: await _decodeImages(arguments['images']),
          );
        case AiWindowOp.stop:
          task.stop(message: arguments['message'] as String?);
        case AiWindowOp.approve:
          task.approve(arguments['allowed'] == true);
        case AiWindowOp.setModel:
          task.setModel(arguments['model'] as String?);
        case AiWindowOp.setApprovalMode:
          task.setApprovalMode(_modeFrom(arguments['mode']));
        case AiWindowOp.setAutoApprove:
          task.setAutoApprove(arguments['enabled'] == true);
        case AiWindowOp.listModels:
          return <String, Object?>{'models': await task.listModels()};
        case AiWindowOp.loadHistory:
          await task.loadHistory();
        case AiWindowOp.newConversation:
          await task.newConversation();
        case AiWindowOp.openConversation:
          await task.openConversation(arguments['id'] as String? ?? '');
        case AiWindowOp.deleteConversation:
          await task.deleteConversation(arguments['id'] as String? ?? '');
        case AiWindowOp.previewConversation:
          return await _preview(arguments['id'] as String? ?? '');
        case AiWindowOp.settings:
          onSettings?.call();
        default:
          throw MissingPluginException('Unknown AI window operation');
      }
      return null;
    } on AiFailure catch (error) {
      throw PlatformException(code: 'ai', message: error.message);
    } on PlatformException {
      rethrow;
    } on MissingPluginException {
      rethrow;
    } catch (_) {
      throw PlatformException(code: 'ai', message: '操作未完成，请重试');
    }
  }

  Future<Object?> _preview(String id) async {
    final entries = await task.previewConversation(id);
    if (entries == null) return null;
    final images = <String, Object?>{};
    return <String, Object?>{
      'entries': [
        for (final entry in entries)
          _encodeEntry(entry, _collect(entry, images)),
      ],
      'images': images,
    };
  }

  Future<List<AiImage>> _decodeImages(Object? raw) async {
    if (raw is! List) return const [];
    final images = <AiImage>[];
    for (final row in raw) {
      if (row is! Map) continue;
      final name = row['name'];
      final bytes = row['bytes'];
      if (name is! String || bytes is! Uint8List) continue;
      images.add(await AiImage.fromBytes(name, bytes));
    }
    AiImage.validateBatch(images);
    return images;
  }

  /// Builds the wire mirror. Only entries that changed since the last push and
  /// images the window has not received yet are included; image bytes are never
  /// repeated for a plain token update.
  Map<String, Object?> snapshot({required bool full}) {
    final entries = task.entries;
    final reset = full || _full || entries.length < _sentEntries.length;
    // Attachments of entries that no longer exist must not stay reachable, and
    // a stale entry at the same index must never lend its reference to a new
    // one ([_refsFor] re-checks identity).
    if (_entryRefs.length > entries.length) {
      _entryRefs.removeRange(entries.length, _entryRefs.length);
    }
    final maps = <Map<String, Object?>>[];
    final refs = <List<String>>[];
    final encoded = <String>[];
    for (var index = 0; index < entries.length; index++) {
      final entryRefs = _refsFor(index, entries[index]);
      refs.add(entryRefs);
      final map = _encodeEntry(entries[index], entryRefs);
      maps.add(map);
      encoded.add(jsonEncode(map));
    }
    final rows = <String, Object?>{};
    final images = <String, Object?>{};
    for (var index = 0; index < maps.length; index++) {
      if (!reset &&
          index < _sentEntries.length &&
          _sentEntries[index] == encoded[index]) {
        continue;
      }
      rows['$index'] = maps[index];
      _collectImages(refs[index], entries[index], images);
    }
    _sentEntries
      ..clear()
      ..addAll(encoded);
    if (reset) _full = false;
    final pending = task.pending;
    return <String, Object?>{
      'sessionId': sessionId,
      'generation': generation,
      'reset': reset,
      'count': entries.length,
      'entries': rows,
      'images': images,
      'hostName': hostName,
      'running': task.running,
      'status': task.status,
      'failure': task.failure,
      'pending': pending == null
          ? null
          : <String, Object?>{
              'id': pending.id,
              'name': pending.name,
              'command': pending.command,
              'reason': pending.reason,
              'requiresApproval': pending.requiresApproval,
              'arguments': pending.arguments,
            },
      'approvalMode': task.approvalMode.name,
      'turnStartedAt': task.turnStartedAt?.toIso8601String(),
      'settings': _publicSettings(task.settings()),
      'appearance': host.appearance().toJson(),
      'settingsAvailable': onSettings != null,
      'history': <String, Object?>{
        'loading': task.historyLoading,
        'failure': task.historyFailure,
        'activeId': task.activeConversationId,
        'conversations': [for (final item in task.conversations) item.toJson()],
      },
    };
  }

  /// Content references of the attachments of one entry, cached per index.
  ///
  /// The cache is only reused while the entry still holds the very same image
  /// instances, so an entry created later at the same index can never inherit
  /// another attachment's reference.
  List<String> _refsFor(int index, AiTaskEntry entry) {
    final images = entry.images ?? const <AiImage>[];
    if (index < _entryRefs.length) {
      final cached = _entryRefs[index];
      if (_sameImageList(cached.images, images)) return cached.refs;
    }
    final refs = [
      for (final image in images) _imageRef(image.name, image.bytes),
    ];
    while (_entryRefs.length <= index) {
      _entryRefs.add(const _EntryRefs([], []));
    }
    _entryRefs[index] = _EntryRefs(images, refs);
    return refs;
  }

  void _collectImages(
    List<String> refs,
    AiTaskEntry entry,
    Map<String, Object?> images,
  ) {
    final list = entry.images ?? const <AiImage>[];
    for (var index = 0; index < list.length && index < refs.length; index++) {
      final ref = refs[index];
      if (!_sentImages.add(ref)) continue;
      images[ref] = <String, Object?>{
        'name': list[index].name,
        'bytes': list[index].bytes,
      };
    }
  }

  /// Same as [_collectImages] for entries that are not part of the live list
  /// (conversation previews), so preview images cross the channel once too.
  List<String> _collect(AiTaskEntry entry, Map<String, Object?> images) {
    final refs = [
      for (final image in entry.images ?? const <AiImage>[])
        _imageRef(image.name, image.bytes),
    ];
    _collectImages(refs, entry, images);
    return refs;
  }
}

/// Cached content references of one entry's attachments.
class _EntryRefs {
  const _EntryRefs(this.images, this.refs);
  final List<AiImage> images;
  final List<String> refs;
}

bool _sameImageList(List<AiImage> left, List<AiImage> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

AiApprovalMode _modeFrom(Object? value) {
  if (value is! String) return AiApprovalMode.manual;
  for (final mode in AiApprovalMode.values) {
    if (mode.name == value) return mode;
  }
  return AiApprovalMode.manual;
}

/// Values the detached window is allowed to know. The API key and the provider
/// profiles (they embed keys) never leave the main engine.
Map<String, Object?> _publicSettings(AiSettings settings) => <String, Object?>{
  'baseUrl': settings.baseUrl,
  'model': settings.model,
  'protocol': (settings.protocol ?? AiProtocol.openai).name,
  'provider': settings.provider ?? 'custom',
  'approvalModel': settings.approvalModel,
  'approvalProvider': settings.approvalProvider,
};

Map<String, Object?> _encodeEntry(AiTaskEntry entry, List<String> refs) =>
    <String, Object?>{
      'text': entry.text,
      'command': entry.command,
      'user': entry.user,
      'notice': entry.notice,
      'model': entry.model,
      'output': entry.output,
      'reason': entry.reason,
      'exitCode': entry.exitCode,
      'finished': entry.finished,
      'started': entry.started,
      'interruption': entry.interruption,
      'images': refs,
    };

final _crc32Table = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (var index = 0; index < bytes.length; index++) {
    crc = _crc32Table[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Content address of one attachment.
///
/// Both engines compute it from the same name and bytes, so an image crosses
/// the channel once per child engine: a token update only sends the reference,
/// and a conversation reopened in either window reuses the cached bytes.
String _imageRef(String name, Uint8List bytes) =>
    '$name|${bytes.length}|${_crc32(bytes).toRadixString(16)}';

/// Second-engine proxy for the terminal AI panel.
///
/// It is an [AiTaskController] so [TerminalAiPanel] keeps its concrete type, but
/// it owns no API client, no command executor and no conversation store: every
/// read is a mirror of the main engine and every write is forwarded. The panel
/// therefore renders and behaves exactly as it does inside the main window.
class RemoteAiTaskController extends AiTaskController {
  RemoteAiTaskController._(_RemoteMirror mirror)
    : _mirror = mirror,
      super(
        settings: () => mirror.settings,
        executorFactory: _noLocalExecutor,
        connected: () => true,
        clientFactory: _noLocalClient,
      );

  factory RemoteAiTaskController() => RemoteAiTaskController._(_RemoteMirror());

  final _RemoteMirror _mirror;
  final _images = <String, AiImage?>{};
  Future<void> _pipeline = Future<void>.value();
  bool _disposed = false;
  bool _resyncPending = false;

  @override
  List<AiConversationSummary> get conversations =>
      List.unmodifiable(_mirror.conversations);

  @override
  String? get activeConversationId => _mirror.activeConversationId;

  @override
  bool get historyLoading => _mirror.historyLoading;

  @override
  String? get historyFailure => _mirror.historyFailure;

  /// Session mirrored into this window, or null when it is closed.
  String? get sessionId => _mirror.sessionId;

  String get hostName => _mirror.hostName;

  bool get settingsAvailable => _mirror.settingsAvailable;

  AppearancePreferences get appearance => _mirror.appearance;

  /// Completes when every mirror received so far has been applied.
  @visibleForTesting
  Future<void> get applied => _pipeline;

  /// Startup handshake: registers the relay and asks the main engine for the
  /// first mirror. Missing native support leaves the window in its closed state
  /// instead of surfacing a platform error.
  Future<void> initialize() async {
    aiWindowChannel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _enqueue(call.arguments);
      return null;
    });
    try {
      _enqueue(
        await aiWindowChannel.invokeMethod<Object?>('state', <String, Object?>{
          'ready': true,
        }),
      );
    } on MissingPluginException {
      _clear();
    } on PlatformException catch (error) {
      _fail(error.message ?? '无法连接主窗口的 AI 会话');
    } catch (_) {
      _fail('无法连接主窗口的 AI 会话');
    }
    await _pipeline;
  }

  /// Applies one mirror payload relayed by the native window.
  Future<void> applyMirror(Object? payload) {
    _enqueue(payload);
    return _pipeline;
  }

  /// Asks the main engine to take the panel back and hides this window.
  Future<void> dock() async {
    if (_disposed) return;
    final session = _mirror.sessionId;
    try {
      await aiWindowChannel.invokeMethod<void>(
        'dock',
        session == null ? null : <String, Object?>{'sessionId': session},
      );
    } catch (_) {
      // Native hides the window itself; a failed relay keeps it visible.
    }
  }

  Future<void> openSettings() => _forward(AiWindowOp.settings);

  // --- user actions: forwarded, never executed here --------------------------

  @override
  Future<void> start(String goal, {List<AiImage> images = const []}) async {
    if (_disposed) return;
    for (final image in images) {
      // These bytes came from this engine, so the mirror can resolve its own
      // reference without a round trip.
      _images[_imageRef(image.name, image.bytes)] = image;
    }
    await _forward(AiWindowOp.start, <String, Object?>{
      'goal': goal,
      'images': [
        for (final image in images)
          <String, Object?>{'name': image.name, 'bytes': image.bytes},
      ],
    });
  }

  /// Closing the detached window must never stop the turn: only an explicit
  /// stop from the panel forwards one.
  @override
  void stop({String? message}) {
    if (_disposed) return;
    unawaited(_forward(AiWindowOp.stop, <String, Object?>{'message': message}));
  }

  @override
  void approve(bool allowed) {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.approve, <String, Object?>{'allowed': allowed}),
    );
  }

  @override
  void setModel(String? model) {
    if (_disposed) return;
    unawaited(_forward(AiWindowOp.setModel, <String, Object?>{'model': model}));
  }

  @override
  void setApprovalMode(AiApprovalMode mode) {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.setApprovalMode, <String, Object?>{
        'mode': mode.name,
      }),
    );
  }

  @override
  void setAutoApprove(bool enabled) {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.setAutoApprove, <String, Object?>{
        'enabled': enabled,
      }),
    );
  }

  @override
  Future<List<String>> listModels() async {
    if (_disposed) return const [];
    final result = await _forward(AiWindowOp.listModels);
    if (result is Map && result['models'] is List) {
      return [for (final item in result['models'] as List) '$item'];
    }
    if (failure != null) throw AiFailure(failure!);
    return const [];
  }

  @override
  Future<void> loadHistory() => _forward(AiWindowOp.loadHistory);

  @override
  Future<void> newConversation() => _forward(AiWindowOp.newConversation);

  @override
  Future<void> openConversation(String id) =>
      _forward(AiWindowOp.openConversation, <String, Object?>{'id': id});

  @override
  Future<void> deleteConversation(String id) =>
      _forward(AiWindowOp.deleteConversation, <String, Object?>{'id': id});

  @override
  Future<List<AiTaskEntry>?> previewConversation(String id) async {
    if (_disposed) return null;
    final result = await _forward(AiWindowOp.previewConversation, {'id': id});
    // A preview that lands after the window moved on is dropped: it belongs to
    // a conversation the user is no longer looking at.
    if (_disposed || result is! Map) return null;
    final raw = result['images'];
    if (raw is Map) {
      for (final item in raw.entries) {
        final value = item.value;
        if (value is! Map) continue;
        final name = value['name'];
        final bytes = value['bytes'];
        if (name is! String || bytes is! Uint8List) continue;
        final ref = '${item.key}';
        if (_images.containsKey(ref)) continue;
        _images[ref] = await _decode(name, bytes);
      }
    }
    final rows = result['entries'] is List
        ? result['entries'] as List
        : const [];
    return <AiTaskEntry>[
      for (final row in rows)
        if (row is Map) _entryFromMap(row),
    ];
  }

  @override
  void dispose() {
    // Base `dispose` calls `stop`; marking the proxy disposed first keeps that
    // local teardown from forwarding a stop to the running main-engine turn.
    if (_disposed) return;
    _disposed = true;
    aiWindowChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _forward(String op, [Map<String, Object?>? arguments]) async {
    if (_disposed) return null;
    final session = _mirror.sessionId;
    final generation = _mirror.generation;
    Object? reply;
    try {
      reply = await aiWindowChannel.invokeMethod<Object?>('action', {
        'sessionId': session,
        'op': op,
        'args': arguments ?? const <String, Object?>{},
      });
    } on PlatformException catch (error) {
      _fail(error.message ?? '操作未完成，请重试');
      return null;
    } on MissingPluginException {
      _fail('独立窗口不可用，请从主窗口继续操作');
      return null;
    } catch (_) {
      _fail('操作未完成，请重试');
      return null;
    }
    if (_disposed) return null;
    if (session != _mirror.sessionId || generation != _mirror.generation) {
      // Late result of a session the window no longer shows.
      return null;
    }
    if (reply is! Map) return null;
    final state = reply['state'];
    if (state != null) _enqueue(state);
    return reply['result'];
  }

  void _fail(String message) {
    if (_disposed) return;
    failure = message;
    notifyListeners();
  }

  void _enqueue(Object? payload) {
    if (_disposed) return;
    _pipeline = _pipeline
        .then((_) => _apply(payload))
        .catchError((Object _) {});
  }

  Future<void> _apply(Object? raw) async {
    if (_disposed || raw is! Map) return;
    final session = raw['sessionId'];
    if (session is! String) {
      _clear();
      return;
    }
    if (raw['closed'] == true) {
      _clear();
      return;
    }
    final generation = raw['generation'] is int ? raw['generation'] as int : 0;
    final switched =
        session != _mirror.sessionId || generation != _mirror.generation;
    _mirror
      ..sessionId = session
      ..generation = generation;
    final reset = switched || raw['reset'] == true;
    if (switched && raw['reset'] != true) {
      // A session switch always arrives as a full mirror; an incremental one
      // would leave entries this engine never had. Ask for the real thing.
      _resync();
      return;
    }
    final count = raw['count'] is int ? raw['count'] as int : entries.length;
    // A shorter payload without a reset is drift (a lost message), never a real
    // state; appends are normal and arrive as patches for the new indices.
    if (!reset && count < entries.length) {
      _resync();
      return;
    }
    final images = raw['images'];
    if (images is Map) {
      for (final item in images.entries) {
        final ref = '${item.key}';
        if (_images.containsKey(ref)) continue;
        final value = item.value;
        if (value is! Map) continue;
        final name = value['name'];
        final bytes = value['bytes'];
        if (name is! String || bytes is! Uint8List) continue;
        _images[ref] = await _decode(name, bytes);
      }
    }
    _resyncPending = false;
    final rows = raw['entries'] is Map ? raw['entries'] as Map : const {};
    final missing = <String>{};
    _applyEntries(rows, count, reset, missing);
    _applyScalars(raw);
    notifyListeners();
    if (missing.isNotEmpty) _resync();
  }

  /// Asks for a full mirror when bytes referenced by an entry never arrived.
  void _resync() {
    if (_disposed || _resyncPending) return;
    _resyncPending = true;
    unawaited(() async {
      try {
        final state = await aiWindowChannel.invokeMethod<Object?>(
          'state',
          <String, Object?>{'resync': true, 'sessionId': _mirror.sessionId},
        );
        _enqueue(state);
      } catch (_) {
        _resyncPending = false;
      }
    }());
  }

  void _applyEntries(Map rows, int count, bool reset, Set<String> missing) {
    final decoded = <int, AiTaskEntry>{};
    for (final item in rows.entries) {
      final index = int.tryParse('${item.key}');
      final value = item.value;
      if (index == null || value is! Map) continue;
      decoded[index] = _entryFromMap(value, missing: missing);
    }
    if (reset) {
      final next = <AiTaskEntry>[];
      for (var index = 0; index < count; index++) {
        next.add(decoded[index] ?? AiTaskEntry(''));
      }
      entries
        ..clear()
        ..addAll(next);
      return;
    }
    for (final item in decoded.entries) {
      final index = item.key;
      if (index >= count) continue;
      while (entries.length <= index) {
        entries.add(AiTaskEntry(''));
      }
      final existing = entries[index];
      final incoming = item.value;
      if (_sameIdentity(existing, incoming)) {
        _copyMutable(existing, incoming);
      } else {
        entries[index] = incoming;
      }
    }
    // Entries the payload announced but did not carry keep their slot so the
    // list length stays in step with the main engine.
    while (entries.length < count) {
      entries.add(AiTaskEntry(''));
    }
  }

  void _applyScalars(Map raw) {
    running = raw['running'] == true;
    status = raw['status'] is String ? raw['status'] as String : '';
    failure = raw['failure'] is String ? raw['failure'] as String : null;
    pending = _pendingFrom(raw['pending']);
    if (raw['approvalMode'] is String) {
      approvalMode = _modeFrom(raw['approvalMode']);
    }
    turnStartedAt = raw['turnStartedAt'] is String
        ? DateTime.tryParse(raw['turnStartedAt'] as String)
        : null;
    final settings = raw['settings'];
    if (settings is Map) _mirror.settings = AiSettings.fromJson(settings);
    final appearance = raw['appearance'];
    if (appearance is Map) {
      _mirror.appearance = AppearancePreferences.fromJson(appearance);
    }
    if (raw['hostName'] is String) _mirror.hostName = raw['hostName'] as String;
    _mirror.settingsAvailable = raw['settingsAvailable'] == true;
    final history = raw['history'];
    if (history is Map) {
      _mirror.historyLoading = history['loading'] == true;
      _mirror.historyFailure = history['failure'] is String
          ? history['failure'] as String
          : null;
      _mirror.activeConversationId = history['activeId'] is String
          ? history['activeId'] as String
          : null;
      final list = history['conversations'];
      _mirror.conversations = [
        for (final row in list is List ? list : const [])
          if (row is Map)
            AiConversationSummary(
              id: '${row['id'] ?? ''}',
              title: '${row['title'] ?? ''}',
              model: '${row['model'] ?? ''}',
              updatedAt:
                  DateTime.tryParse('${row['updatedAt']}') ??
                  DateTime.fromMillisecondsSinceEpoch(0),
            ),
      ];
    }
  }

  /// The main engine dropped the session (its SSH pane was closed).
  void _clear() {
    _mirror
      ..sessionId = null
      ..generation = 0
      ..conversations = const []
      ..activeConversationId = null
      ..historyFailure = null
      ..historyLoading = false;
    _resyncPending = false;
    if (entries.isEmpty && !running && pending == null && failure == null) {
      status = 'AI 会话已关闭，请从主窗口重新打开';
      notifyListeners();
      return;
    }
    entries.clear();
    running = false;
    pending = null;
    failure = null;
    turnStartedAt = null;
    status = 'AI 会话已关闭，请从主窗口重新打开';
    notifyListeners();
  }

  Future<AiImage?> _decode(String name, Uint8List bytes) async {
    try {
      return await AiImage.fromBytes(name, bytes);
    } catch (_) {
      // An attachment this engine cannot decode is dropped from the mirror;
      // the main engine still holds it for the model.
      return null;
    }
  }

  AiTaskEntry _entryFromMap(Map row, {Set<String>? missing}) {
    final refs = row['images'];
    final images = <AiImage>[];
    for (final ref in refs is List ? refs : const []) {
      final key = '$ref';
      if (!_images.containsKey(key) && missing != null) missing.add(key);
      final image = _images[key];
      if (image != null) images.add(image);
    }
    final entry = AiTaskEntry(
      row['text'] is String ? row['text'] as String : '',
      command: row['command'] == true,
      images: images.isEmpty ? null : List.unmodifiable(images),
      user: row['user'] is bool ? row['user'] as bool : null,
      notice: row['notice'] is bool ? row['notice'] as bool : null,
      model: row['model'] is String ? row['model'] as String : null,
    );
    entry.output = row['output'] is String ? row['output'] as String : '';
    entry.reason = row['reason'] is String ? row['reason'] as String : null;
    entry.exitCode = row['exitCode'] is int ? row['exitCode'] as int : null;
    entry.finished = row['finished'] == true;
    entry.started = row['started'] is bool ? row['started'] as bool : null;
    entry.interruption = row['interruption'] is String
        ? row['interruption'] as String
        : null;
    return entry;
  }
}

bool _sameIdentity(AiTaskEntry a, AiTaskEntry b) {
  if (a.command != b.command ||
      a.user != b.user ||
      a.notice != b.notice ||
      a.model != b.model) {
    return false;
  }
  final left = a.images ?? const <AiImage>[];
  final right = b.images ?? const <AiImage>[];
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

/// Entries are keys for their bubbles, so a plain token update keeps the same
/// object; only a changed user/notice/model/attachment set replaces it.
void _copyMutable(AiTaskEntry target, AiTaskEntry source) {
  target.text = source.text;
  target.output = source.output;
  target.reason = source.reason;
  target.exitCode = source.exitCode;
  target.finished = source.finished;
  target.started = source.started;
  target.interruption = source.interruption;
}

AiToolCall? _pendingFrom(Object? raw) {
  if (raw is! Map) return null;
  final arguments = raw['arguments'];
  return AiToolCall(
    '${raw['id'] ?? ''}',
    '${raw['command'] ?? ''}',
    '${raw['reason'] ?? ''}',
    raw['requiresApproval'] == true,
    name: raw['name'] is String ? raw['name'] as String : 'run_command',
    arguments: arguments is Map
        ? {
            for (final item in arguments.entries)
              if (item.key is String) item.key as String: item.value,
          }
        : const {},
  );
}

/// The detached engine never talks to a model or a server itself.
TerminalAiClient _noLocalClient() => throw const AiFailure('AI 请求只能由主窗口执行');

AiCommandExecutor _noLocalExecutor() => throw const AiFailure('AI 命令只能由主窗口执行');

/// Mirror storage of the detached engine.
class _RemoteMirror {
  AiSettings settings = const AiSettings();
  AppearancePreferences appearance = const AppearancePreferences();
  String hostName = 'Harbor SSH';
  bool settingsAvailable = false;
  String? sessionId;
  int generation = 0;
  List<AiConversationSummary> conversations = const [];
  String? activeConversationId;
  bool historyLoading = false;
  String? historyFailure;
}
