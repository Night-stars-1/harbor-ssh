import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/ai_conversation_store.dart';
import '../data/ai_image.dart';
import '../data/terminal_ai.dart';
import '../domain/appearance.dart';
import 'ai_task_controller.dart';
import 'ai_window_session.dart';

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

  /// Verifies the password of the exact pending `request_root` call. The
  /// password travels as a transient argument of this action only.
  static const authorizeRoot = 'authorizeRoot';

  /// Ends this turn's root session. A running turn is stopped, never silently
  /// downgraded and continued. The request names the turn it was rendered for
  /// ([AiTaskController.turnStartedAt]) and is ignored once that turn is gone.
  static const endRoot = 'endRoot';
  static const setModel = 'setModel';
  static const setReasoningEffort = 'setReasoningEffort';
  static const setApprovalMode = 'setApprovalMode';
  static const setAutoApprove = 'setAutoApprove';
  static const listModels = 'listModels';
  static const loadHistory = 'loadHistory';
  static const newConversation = 'newConversation';
  static const openConversation = 'openConversation';
  static const deleteConversation = 'deleteConversation';
  static const previewConversation = 'previewConversation';
  static const settings = 'settings';

  /// Switches the detached window to another open SSH session.
  static const openSession = 'openSession';
}

/// Owns the AI controller of every SSH session and mirrors the one session that
/// is currently detached into the native window.
///
/// One controller stays the single owner of the SSH executor, the API client
/// and the encrypted conversation store; the second engine only renders and
/// forwards. `changed`/`state` payloads never carry an API key, an SSH secret
/// or command text typed outside the conversation.
///
/// The one credential that does cross the channel is a root password submitted
/// in the detached window, and only as the transient `authorizeRoot` action
/// argument: the mirror reports [`rootActive`], [`authorizingRoot`] and a fixed
/// [`privilegeError`] instead of anything derived from it, so nothing about the
/// password is ever echoed back, stored or logged.
class AiWindowHost extends ChangeNotifier {
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

  /// Supplies every SSH session the main window currently has open, whether or
  /// not it ever opened the assistant. Installed by [TerminalWorkspace].
  List<AiWindowSession> Function()? _catalog;

  /// Creates (and registers) the controller of a session that has none yet.
  Future<bool> Function(String sessionId)? _ensure;

  String _catalogSignature = '';

  /// Host-wide counter behind [_DetachedSession.generation]. Deriving it from
  /// the previous registration alone would restart at 1 after an unregister,
  /// letting a late action from the old window match the replacement mirror.
  int _generationSerial = 0;

  /// Binds the authoritative session directory.
  ///
  /// [catalog] is re-read on every push, so it always reflects the sessions the
  /// main window has open. [ensure] lazily materializes the real controller of a
  /// session that has never opened the assistant, so the detached window can
  /// switch to it without the main window pre-creating anything.
  void bindSessions({
    required List<AiWindowSession> Function() catalog,
    required Future<bool> Function(String sessionId) ensure,
  }) {
    _catalog = catalog;
    _ensure = ensure;
    _catalogSignature = '';
    _refreshCatalog();
  }

  void unbindSessions() {
    _catalog = null;
    _ensure = null;
    _catalogSignature = '';
  }

  /// Session mirrored by the detached window, or null when it is hidden.
  String? get openSessionId => _sessionId;

  /// Whether [sessionId] is the session currently shown in the detached window.
  bool isDetached(String sessionId) => _sessionId == sessionId;

  /// Re-reads the session directory and pushes it when it changed (SSH opened,
  /// closed, connected or disconnected, a background turn started or stopped).
  void refreshSessions() => _refreshCatalog();

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
  /// The generation is a host-wide serial, so closing and reopening the same
  /// session id never hands the new mirror a value an old window still holds.
  void register(
    String sessionId,
    AiTaskController task,
    String hostName, {
    required VoidCallback onDock,
    VoidCallback? onSettings,
  }) {
    final previous = _sessions[sessionId];
    // The very same controller (the pane adopted one the workspace created
    // lazily, or re-registered itself) keeps its generation and conversation:
    // only the metadata and the dock callback are refreshed.
    if (previous != null && identical(previous.task, task)) {
      previous
        ..hostName = hostName
        ..onDock = onDock
        ..onSettings = onSettings;
      if (_sessionId == sessionId) previous.markDirty(immediate: true);
      return;
    }
    final session = _DetachedSession(
      this,
      sessionId,
      task,
      hostName,
      onDock,
      onSettings,
      ++_generationSerial,
    );
    _sessions[sessionId] = session;
    task.addListener(session.markDirty);
    previous?.detach();
    if (_sessionId == sessionId) session.rebuild();
    _refreshCatalog();
  }

  /// Releases [sessionId]. A detached window is told that the session is gone
  /// and the native window is hidden; the task is never stopped here.
  void unregister(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    session.detach();
    if (_sessionId != sessionId) {
      _refreshCatalog();
      return;
    }
    _sessionId = null;
    // The list must already reflect the removal when the window is told.
    _refreshCatalog();
    session.announceClosed();
    notifyListeners();
  }

  /// Creates (or wakes) the single native AI window and mirrors [sessionId].
  ///
  /// No sensitive value crosses the channel or the process arguments. Check
  /// [isDetached] afterwards: a window that could not be created leaves the
  /// session embedded in the main window.
  Future<void> open(String sessionId) async {
    final session = await _materialize(sessionId);
    if (session == null) return;
    final previous = _sessionId;
    // The session is claimed silently: the panes must not see an embedded
    // panel flicker while the native window is still being created.
    _setSession(sessionId, notify: false);
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
      notifyListeners();
      _refreshCatalog();
      return;
    }
    if (_sessionId != sessionId) return;
    // One native window shows one conversation. The pane that lost it embeds
    // its panel again; the task itself keeps running.
    if (previous != null && previous != sessionId) {
      _sessions[previous]?.reembed();
    }
    notifyListeners();
    _refreshCatalog();
    await session.flush();
  }

  /// Ensures [sessionId] has a controller and mirrors it in the native window.
  ///
  /// A session that never opened the assistant is materialized on demand by the
  /// catalog's `ensure` hook, so the window can switch to any open SSH session.
  /// Returns whether the window ended up showing [sessionId].
  Future<bool> openSession(String sessionId) async {
    await open(sessionId);
    return _sessionId == sessionId;
  }

  /// The registered session, materializing its controller through the catalog
  /// hook when the window has never shown it.
  Future<_DetachedSession?> _materialize(String sessionId) async {
    final existing = _sessions[sessionId];
    if (existing != null) return existing;
    final ensure = _ensure;
    if (ensure == null) return null;
    if (!await ensure(sessionId)) return null;
    return _sessions[sessionId];
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

  @override
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
    super.dispose();
  }

  void _setSession(String? id, {bool notify = true}) {
    if (_sessionId == id) return;
    // Mirror caches survive a switch: image bytes are content addressed and the
    // child engine keeps its cache, so returning to a session only resends the
    // entries. A child that restarts clears them through its `state` handshake.
    _sessionId = id;
    if (notify) notifyListeners();
  }

  /// Sessions the main window has open, as last read from the catalog.
  List<AiWindowSession> _sessionsList() {
    final catalog = _catalog;
    if (catalog == null) return const [];
    try {
      return catalog();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, Object?>> _encodedSessions() => [
    for (final session in _sessionsList()) session.toJson(),
  ];

  /// Pushes the session directory when its visible shape changed. Cheap to call
  /// on every SSH or task notification: an unchanged list never pushes.
  void _refreshCatalog() {
    final signature = _sessionsList()
        .map(
          (session) =>
              '${session.id}|${session.hostName}|${session.endpoint}'
              '|${session.connected}|${session.running}'
              '|${session.waitingApproval}'
              '|${session.rootActive}|${session.authorizingRoot}',
        )
        .join('\n');
    if (signature == _catalogSignature) return;
    _catalogSignature = signature;
    final id = _sessionId;
    if (id == null) return;
    _sessions[id]?.markDirty(immediate: true);
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
    final op = map['op'];
    if (op is! String) {
      throw PlatformException(code: 'op', message: '无效的 AI 窗口操作');
    }
    // A switch carries the session the window is on right now; it must be
    // validated against the main engine before the window is moved.
    if (op == AiWindowOp.openSession) return _openSessionAction(map);
    final requested = map['sessionId'];
    final session = _sessions[requested is String ? requested : _sessionId];
    if (session == null) {
      throw PlatformException(code: 'session', message: 'AI 会话已关闭，请从主窗口重新打开');
    }
    final argumentsMap = map['args'] is Map
        ? Map<String, Object?>.from(map['args'] as Map)
        : const <String, Object?>{};
    final generation = session.generation;
    // A privilege decision belongs to one exact mirror generation: a window
    // that saw a pane which has since been rebuilt must neither elevate nor
    // stop the controller that replaced it.
    if ((op == AiWindowOp.authorizeRoot || op == AiWindowOp.endRoot) &&
        map['generation'] != generation) {
      final mirrored = _sessionId == null ? null : _sessions[_sessionId];
      return <String, Object?>{
        'state':
            mirrored?.snapshot(full: true) ??
            const <String, Object?>{'sessionId': null},
      };
    }
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

  /// Switches the detached window to another open SSH session.
  ///
  /// The request carries the origin session and its mirror generation. A select
  /// that arrives after the window already moved (or after its pane was
  /// rebuilt) is rejected instead of dragging the user back to an old session.
  Future<Object?> _openSessionAction(Map map) async {
    final args = map['args'] is Map
        ? Map<String, Object?>.from(map['args'] as Map)
        : const <String, Object?>{};
    final target = args['id'];
    final requested = map['sessionId'];
    final current = _sessionId == null ? null : _sessions[_sessionId];
    if (_sessionId != null) {
      // The window is on a session: the origin must still be that session with
      // the generation the window saw, otherwise this is a late select.
      final origin = requested is String ? _sessions[requested] : null;
      final generation = map['generation'];
      if (origin == null ||
          _sessionId != requested ||
          origin.generation != generation) {
        return <String, Object?>{'state': current?.snapshot(full: true)};
      }
    }
    if (target is! String || target.isEmpty) {
      return <String, Object?>{'state': current?.snapshot(full: true)};
    }
    if (target == _sessionId) {
      return <String, Object?>{
        'state': _sessions[target]?.snapshot(full: false),
      };
    }
    final switched = await openSession(target);
    final session = _sessionId == null ? null : _sessions[_sessionId];
    return <String, Object?>{
      'state': session?.snapshot(full: true),
      'result': switched,
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
  String hostName;
  VoidCallback onDock;
  VoidCallback? onSettings;

  /// Unique within the host: bumped on every registration of a new controller,
  /// never reused even after the session id is unregistered.
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
    if (_disposed) return;
    if (!_mirrored) {
      // A background session's turn state is part of the session directory the
      // window shows; refresh it without touching the mirrored conversation.
      host._refreshCatalog();
      return;
    }
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
        'sessions': host._encodedSessions(),
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
          final expected = arguments['callId'];
          // The click carries the call id the window rendered. A late or
          // duplicated action from an earlier prompt must never decide the
          // call that replaced it (neither grant nor cancel).
          if (expected is! String || expected != task.pending?.id) return null;
          task.approve(
            arguments['allowed'] == true,
            saveForward: arguments['saveForward'] == true,
            expectedCallId: expected,
          );
        case AiWindowOp.authorizeRoot:
          final expected = arguments['callId'];
          final password = arguments['password'];
          // The password is an argument of this call only: it is handed to the
          // controller and never stored on the mirror, an entry, the history or
          // a log. A repeated or late submission is dropped by the exact id.
          if (expected is! String || password is! String) return null;
          final current = task.pending;
          if (current == null ||
              current.id != expected ||
              current.name != aiRootToolName) {
            return null;
          }
          try {
            await task.authorizeRoot(password, expectedCallId: expected);
          } catch (_) {
            // The raw error is never rethrown: an exception raised while a
            // password is in flight may quote the credential or the SSH prompt
            // that produced it.
            throw PlatformException(
              code: 'ai',
              message: '提权未完成，请重试',
            );
          }
        case AiWindowOp.endRoot:
          // The only endRoot the panel offers is the root banner, so a turn
          // that holds no root state has nothing to end.
          if (!task.rootActive &&
              !task.authorizingRoot &&
              task.privilegeError == null) {
            return null;
          }
          // The click names the turn it was rendered for. A delayed click that
          // arrives after the model moved on (same controller, therefore the
          // same generation) must not stop a turn that started since — even
          // when that new turn also holds root. No token, no endRoot.
          final expectedTurn = arguments['turnStartedAt'];
          if (expectedTurn != task.turnStartedAt?.toIso8601String()) {
            return null;
          }
          task.endRoot();
        case AiWindowOp.setModel:
          task.setModel(arguments['model'] as String?);
        case AiWindowOp.setReasoningEffort:
          task.setReasoningEffort(_reasoningFrom(arguments['effort']));
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
      // Root state only, never the password that produced it.
      'rootActive': task.rootActive,
      'authorizingRoot': task.authorizingRoot,
      'privilegeError': task.privilegeError,
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
      'settings': _publicSettings(
        task.settings(),
        reasoningEffort: task.reasoningEffort,
      ),
      'appearance': host.appearance().toJson(),
      'settingsAvailable': onSettings != null,
      'sessions': host._encodedSessions(),
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

AiReasoningEffort _reasoningFrom(Object? value) {
  if (value is! String) return AiReasoningEffort.automatic;
  for (final effort in AiReasoningEffort.values) {
    if (effort.name == value) return effort;
  }
  return AiReasoningEffort.automatic;
}

/// Values the detached window is allowed to know. The API key, the provider
/// profiles (they embed keys), the prompt and the MCP servers never leave the
/// main engine: MCP headers can carry bearer tokens, and the detached window
/// needs neither to render or approve a tool call.
Map<String, Object?> _publicSettings(
  AiSettings settings, {
  AiReasoningEffort? reasoningEffort,
}) => <String, Object?>{
  'baseUrl': settings.baseUrl,
  'model': settings.model,
  'protocol': (settings.protocol ?? AiProtocol.openai).name,
  'provider': settings.provider ?? 'custom',
  'approvalModel': settings.approvalModel,
  'approvalProvider': settings.approvalProvider,
  'defaultApprovalMode': settings.defaultApprovalMode.name,
  // Session override first: the mirrored window must show what will be sent.
  'reasoningEffort': (reasoningEffort ?? settings.reasoningEffort).name,
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
class RemoteAiTaskController extends AiTaskController
    implements AiWindowSessionSelection {
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
  bool _selecting = false;

  /// A password was submitted and its forward is still in flight. Holds no
  /// secret: session, generation and the call id are enough to decide whether
  /// the verifying state still describes the mirrored conversation.
  ({int serial, String? session, int generation, String callId})?
  _rootSubmission;
  int _rootSubmissionSerial = 0;

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
  @override
  String? get sessionId => _mirror.sessionId;

  /// Every SSH session the main window has open, mirrored for the session
  /// picker. Credential-free: id, host name, endpoint and live state only.
  /// Empty until the first mirror arrives.
  @override
  List<AiWindowSession> get sessions => _mirror.sessions;

  /// Whether a switch is in flight; the picker disables itself meanwhile.
  @override
  bool get selectingSession => _selecting;

  String get hostName => _mirror.hostName;

  bool get settingsAvailable => _mirror.settingsAvailable;

  AppearancePreferences get appearance => _mirror.appearance;

  /// Whether the main-engine turn currently runs commands as root. Read from
  /// the mirror: the detached engine never elevates anything itself.
  @override
  bool get rootActive => _mirror.rootActive;

  /// True while a submitted password is being verified. The in-flight forward
  /// counts only for the conversation that submitted it: switching to another
  /// session, a rebuilt pane or a newer pending call never inherits it, so an
  /// unrelated prompt is not left locked behind someone else's verification.
  @override
  bool get authorizingRoot {
    if (_mirror.authorizingRoot) return true;
    final submission = _rootSubmission;
    if (submission == null) return false;
    return submission.session == _mirror.sessionId &&
        submission.generation == _mirror.generation &&
        submission.callId == pending?.id;
  }

  /// Fixed, credential-free reason the last root authorization failed.
  @override
  String? get privilegeError => _mirror.privilegeError;

  /// Completes when every mirror received so far has been applied.
  @visibleForTesting
  Future<void> get applied => _pipeline;

  /// Asks the main engine to show [id] in this window.
  ///
  /// Returns whether the window ended up on that session. The request carries
  /// the origin session and generation so a late select cannot drag the window
  /// back to a session it already left. Concurrent selects are ignored.
  @override
  Future<bool> selectSession(String id) async {
    if (_disposed) return false;
    if (_mirror.sessionId == id) return true;
    if (_selecting) return false;
    _selecting = true;
    notifyListeners();
    try {
      await _forward(AiWindowOp.openSession, <String, Object?>{'id': id});
      await _pipeline;
      return !_disposed && _mirror.sessionId == id;
    } finally {
      if (!_disposed) {
        _selecting = false;
        notifyListeners();
      }
    }
  }

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
  void approve(
    bool allowed, {
    bool saveForward = false,
    String? expectedCallId,
  }) {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.approve, <String, Object?>{
        'allowed': allowed,
        'saveForward': saveForward,
        'callId': expectedCallId,
      }),
    );
  }

  /// Verifies [password] for the exact pending `request_root` call in the main
  /// engine.
  ///
  /// The password is an argument of this call only: it is forwarded as a
  /// transient action parameter and never stored on this proxy, the mirror, an
  /// entry, a status, a failure or a log. The main engine re-validates the call
  /// id before touching SSH, so a stale submission authorizes nothing.
  @override
  Future<void> authorizeRoot(
    String password, {
    required String expectedCallId,
  }) async {
    if (_disposed) return;
    final submission = (
      serial: ++_rootSubmissionSerial,
      session: _mirror.sessionId,
      generation: _mirror.generation,
      callId: expectedCallId,
    );
    _rootSubmission = submission;
    notifyListeners();
    try {
      await _forward(AiWindowOp.authorizeRoot, <String, Object?>{
        'password': password,
        'callId': expectedCallId,
      });
    } finally {
      // Only this submission may clear the flag: a newer one, or a switch that
      // already invalidated it, must not be marked finished by an older reply.
      if (_rootSubmission?.serial == submission.serial) {
        _rootSubmission = null;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// Stops this turn and ends its root session. Forwarded, never decided here.
  ///
  /// The click carries the turn it was rendered for: the main engine refuses an
  /// `endRoot` whose turn already ended, so a delayed click can never stop the
  /// turn that replaced it.
  @override
  void endRoot() {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.endRoot, <String, Object?>{
        'turnStartedAt': turnStartedAt?.toIso8601String(),
      }),
    );
  }

  @override
  void setModel(String? model) {
    if (_disposed) return;
    unawaited(_forward(AiWindowOp.setModel, <String, Object?>{'model': model}));
  }

  @override
  void setReasoningEffort(AiReasoningEffort effort) {
    if (_disposed) return;
    unawaited(
      _forward(AiWindowOp.setReasoningEffort, <String, Object?>{
        'effort': effort.name,
      }),
    );
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
        'generation': generation,
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
      // The closed session is already gone from the directory; keep the rest so
      // the window can still offer another SSH session.
      _applySessions(raw);
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
    _mirror
      ..rootActive = raw['rootActive'] == true
      ..authorizingRoot = raw['authorizingRoot'] == true
      ..privilegeError = raw['privilegeError'] is String
          ? raw['privilegeError'] as String
          : null;
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
    _applySessions(raw);
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

  /// Mirrors the SSH session directory. Absent on older payloads, in which case
  /// the last known list is kept.
  void _applySessions(Map raw) {
    final rows = raw['sessions'];
    if (rows is! List) return;
    _mirror.sessions = [
      for (final row in rows)
        if (row is Map) AiWindowSession.fromJson(row),
    ];
  }

  /// The main engine dropped the session (its SSH pane was closed).
  void _clear() {
    _mirror
      ..sessionId = null
      ..generation = 0
      ..conversations = const []
      ..activeConversationId = null
      ..historyFailure = null
      ..historyLoading = false
      ..rootActive = false
      ..authorizingRoot = false
      ..privilegeError = null;
    _resyncPending = false;
    _rootSubmission = null;
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
  List<AiWindowSession> sessions = const [];
  List<AiConversationSummary> conversations = const [];
  String? activeConversationId;
  bool historyLoading = false;
  String? historyFailure;
  bool rootActive = false;
  bool authorizingRoot = false;
  String? privilegeError;
}
