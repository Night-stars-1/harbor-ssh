import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/remote_file.dart';
import 'remote_replace.dart';

const externalOpenChannel = MethodChannel('dev.harborssh/open_file');

/// Folder under the system temporary directory that holds every copy handed
/// to an external application. Android serves it through its FileProvider.
const externalCopiesFolder = 'harbor-external';

/// Whether edits made in the external application are uploaded back. Android
/// cannot observe another app writing to a shared copy, so it only opens a
/// read-only copy.
bool get externalEditsSyncBack => !Platform.isAndroid;

/// Opens the local file at [path] with the system's default application. When
/// no application is associated, the system is asked to offer a choice.
Future<void> openWithSystem(String path) async {
  if (Platform.isAndroid) {
    await externalOpenChannel.invokeMethod<void>('open', path);
    return;
  }
  var opened = false;
  try {
    opened = await launchUrl(Uri.file(path, windows: Platform.isWindows));
  } on PlatformException {
    // Treated like a missing association below.
  }
  if (opened) return;
  if (Platform.isWindows) {
    // Explorer shows "How do you want to open this file?" for unknown types.
    await Process.start('explorer.exe', [
      path.replaceAll('/', r'\'),
    ], mode: ProcessStartMode.detached);
    return;
  }
  if (Platform.isMacOS &&
      (await Process.run('/usr/bin/open', ['-t', path])).exitCode == 0) {
    return;
  }
  throw StateError('没有可以打开此文件的程序');
}

enum ExternalEditStatus {
  /// The remote file is being copied to this device.
  downloading,

  /// The local copy matches the remote file.
  synced,

  /// A change from the external application is being written back.
  uploading,

  /// The remote file changed since it was copied; nothing was uploaded.
  conflict,

  /// The last download or upload failed; see [ExternalEditSession.error].
  failed,

  /// Android: the copy is opened read-only and never uploaded.
  readOnly,
}

/// Raised when the remote file no longer holds the content last synced, so a
/// write-back would silently discard someone else's change.
class ExternalEditConflict implements Exception {
  const ExternalEditConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One remote file opened in an external application.
///
/// The file is copied into a private temporary folder and opened with the
/// system's default application. On desktop the copy is polled: once a change
/// has been stable for one interval it is published with [replaceRemoteFile],
/// after confirming the remote still holds the content last synced.
class ExternalEditSession extends ChangeNotifier {
  ExternalEditSession._(
    this.files,
    this.file,
    this.directory,
    this._launch,
    this._interval,
  ) : local = File(
        '${directory.path}${Platform.pathSeparator}${_localName(file.name)}',
      );

  final RemoteFileSystem files;
  final RemoteFile file;
  final Directory directory;
  final File local;
  final Future<void> Function(String path) _launch;
  final Duration _interval;

  ExternalEditStatus status = ExternalEditStatus.downloading;
  int transferred = 0;
  int? total;
  Object? error;
  DateTime? syncedAt;

  /// Set when an upload published but could not delete its remote backup.
  String? leftoverBackupPath;

  bool get syncBack => status != ExternalEditStatus.readOnly;
  bool get busy =>
      status == ExternalEditStatus.downloading ||
      status == ExternalEditStatus.uploading;

  String? _remoteDigest;
  int? _remoteSize;
  TransferCancellation? _transfer;
  Timer? _poll;
  (int, DateTime)? _seen;
  DateTime? _lastProgress;
  bool _changed = false, _checking = false, _stopped = false;

  Future<void> _start({required bool syncBack}) async {
    final token = _transfer = TransferCancellation();
    total = file.size;
    _notify();
    try {
      final (digest, size) = await _download(token);
      _remoteDigest = digest;
      _remoteSize = size;
      _transfer = null;
      if (_stopped) return;
      syncedAt = DateTime.now();
      status = syncBack
          ? ExternalEditStatus.synced
          : ExternalEditStatus.readOnly;
      _notify();
      await _launch(local.path);
      if (syncBack && !_stopped) {
        _seen = await _stat();
        _poll = Timer.periodic(_interval, (_) => unawaited(check()));
      }
    } catch (e) {
      _transfer = null;
      if (_stopped) return;
      status = ExternalEditStatus.failed;
      error = e;
      _notify();
    }
  }

  Future<(String, int)> _download(TransferCancellation token) async {
    final hash = const DartSha256().newHashSink();
    final output = await local.open(mode: FileMode.writeOnly);
    var size = 0;
    try {
      await files.download(
        file.path,
        (chunk) async {
          hash.add(chunk);
          size += chunk.length;
          await output.writeFrom(chunk);
        },
        cancellation: token,
        onProgress: _progress,
      );
    } finally {
      await output.close();
    }
    hash.close();
    return (_hex((await hash.hash()).bytes), size);
  }

  void _progress(int bytes) {
    transferred = bytes;
    final now = DateTime.now();
    if (_lastProgress != null &&
        now.difference(_lastProgress!).inMilliseconds < 80) {
      return;
    }
    _lastProgress = now;
    _notify();
  }

  /// Opens the local copy again, for example after the application closed.
  Future<void> reopen() async {
    if (_stopped || status == ExternalEditStatus.downloading) return;
    await _launch(local.path);
  }

  /// Uploads the copy when it changed and has been stable for one poll.
  @visibleForTesting
  Future<void> check() async {
    if (_stopped || _checking || busy) return;
    _checking = true;
    try {
      final seen = await _stat();
      if (seen == null) return;
      if (seen != _seen) {
        _seen = seen;
        _changed = true;
        return;
      }
      if (!_changed || status == ExternalEditStatus.conflict) return;
      _changed = false;
      if (await _digest(local.openRead()) == _remoteDigest) return;
      await upload();
    } finally {
      _checking = false;
    }
  }

  /// Writes the local copy back. [overwrite] skips the check that the remote
  /// still holds the content last synced; it still refuses a remote file that
  /// was deleted or replaced by a directory or a link.
  Future<void> upload({bool overwrite = false}) async {
    if (_stopped || busy || !syncBack) return;
    final token = _transfer = TransferCancellation();
    status = ExternalEditStatus.uploading;
    error = null;
    transferred = 0;
    total = (await _stat())?.$1;
    _notify();
    final hash = const DartSha256().newHashSink();
    var size = 0;
    try {
      final leftover = await replaceRemoteFile(
        files,
        file.path,
        local.openRead().map((chunk) {
          hash.add(chunk);
          size += chunk.length;
          return chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        }),
        cancellation: token,
        onProgress: _progress,
        verify: () => _verifyRemote(token, overwrite: overwrite),
      );
      hash.close();
      _remoteDigest = _hex((await hash.hash()).bytes);
      _remoteSize = size;
      leftoverBackupPath = leftover;
      syncedAt = DateTime.now();
      status = ExternalEditStatus.synced;
      // Re-read the copy on the next poll: it may have changed mid-upload.
      _seen = null;
    } on ExternalEditConflict catch (e) {
      status = ExternalEditStatus.conflict;
      error = e;
    } catch (e) {
      if (_stopped) return;
      status = ExternalEditStatus.failed;
      error = e;
    } finally {
      _transfer = null;
      _notify();
    }
  }

  Future<void> _verifyRemote(
    TransferCancellation token, {
    required bool overwrite,
  }) async {
    final current = await statRemoteEntry(files, file.path);
    if (current == null) {
      throw const ExternalEditConflict('远程文件已被删除，本地修改未上传');
    }
    if (current.isDirectory || current.isLink) {
      throw StateError('远程路径已不是普通文件，无法上传');
    }
    if (overwrite) return;
    const changed = ExternalEditConflict('远程文件已被其他人修改，本地修改未上传');
    if (current.size != null && current.size != _remoteSize) throw changed;
    final hash = const DartSha256().newHashSink();
    await files.download(
      file.path,
      (chunk) async => hash.add(chunk),
      cancellation: token,
      onProgress: (_) {},
    );
    hash.close();
    if (_hex((await hash.hash()).bytes) != _remoteDigest) throw changed;
  }

  Future<(int, DateTime)?> _stat() async {
    final stat = await local.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return (stat.size, stat.modified);
  }

  /// Stops syncing and removes the local copy. A transfer in flight is
  /// cancelled before it publishes, so the remote file is left as it was.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _poll?.cancel();
    _transfer?.cancel();
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // The external application may still hold the file open.
    }
  }

  void _notify() {
    if (!_stopped) notifyListeners();
  }

  static Future<String> _digest(Stream<List<int>> source) async {
    final hash = const DartSha256().newHashSink();
    await for (final chunk in source) {
      hash.add(chunk);
    }
    hash.close();
    return _hex((await hash.hash()).bytes);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Remote names may use characters or reserved names Windows rejects; the
  /// extension is kept so the system still picks the right application.
  static String _localName(String name) {
    var safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty ||
        RegExp(
          r'^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$',
          caseSensitive: false,
        ).hasMatch(safe)) {
      safe = '_$safe';
    }
    return safe;
  }
}

/// Every file currently opened in an external application.
class ExternalEdits extends ChangeNotifier {
  ExternalEdits({
    Future<void> Function(String path)? launch,
    Future<Directory> Function()? temporaryDirectory,
    this.pollInterval = const Duration(seconds: 1),
    bool? syncBack,
  }) : _launch = launch ?? openWithSystem,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _syncBack = syncBack ?? externalEditsSyncBack;

  final Future<void> Function(String path) _launch;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration pollInterval;
  final bool _syncBack;
  final _sessions = <ExternalEditSession>[];
  Directory? _root;
  bool _disposed = false;

  List<ExternalEditSession> get sessions => List.unmodifiable(_sessions);

  /// Opens [file] from [files]. A file that is already open keeps its session
  /// and is only shown again; a failed one is replaced by a fresh copy.
  Future<ExternalEditSession> openRemote(
    RemoteFileSystem files,
    RemoteFile file,
  ) async {
    if (file.isDirectory) throw StateError('不能用外部程序打开目录');
    if (file.isLink) throw StateError('不能用外部程序打开符号链接');
    final existing = _sessions
        .where(
          (session) =>
              identical(session.files, files) && session.file.path == file.path,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.status != ExternalEditStatus.failed) {
        await existing.reopen();
        return existing;
      }
      await stop(existing);
    }
    final session = ExternalEditSession._(
      files,
      file,
      await _copyDirectory(),
      _launch,
      pollInterval,
    );
    if (_disposed) {
      await session.stop();
      throw TransferCancelled();
    }
    _sessions.add(session);
    session.addListener(_notify);
    _notify();
    await session._start(syncBack: _syncBack);
    return session;
  }

  /// Opens a file of this device. Android apps cannot be handed a path inside
  /// this app's documents, so a copy under the shared folder is opened there.
  Future<void> openLocal(String path) async {
    if (!Platform.isAndroid) {
      await _launch(path);
      return;
    }
    final directory = await _copyDirectory();
    final name = path.replaceAll('\\', '/').split('/').last;
    final copy = await File(path).copy(
      '${directory.path}${Platform.pathSeparator}${ExternalEditSession._localName(name)}',
    );
    await _launch(copy.path);
  }

  Future<void> stop(ExternalEditSession session) async {
    if (!_sessions.remove(session)) return;
    session.removeListener(_notify);
    _notify();
    await session.stop();
  }

  Future<Directory> _copyDirectory() async {
    final root = _root ??= await _prepareRoot();
    final random = Random.secure();
    final token = List.generate(
      2,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return Directory('${root.path}${Platform.pathSeparator}$token').create();
  }

  /// Copies left by an earlier run that ended without stopping its sessions
  /// may hold sensitive files; anything older than a day is removed.
  Future<Directory> _prepareRoot() async {
    final root = Directory(
      '${(await _temporaryDirectory()).path}${Platform.pathSeparator}$externalCopiesFolder',
    );
    await root.create(recursive: true);
    final stale = DateTime.now().subtract(const Duration(days: 1));
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory && (await entry.stat()).modified.isBefore(stale)) {
          await entry.delete(recursive: true).catchError((Object _) => entry);
        }
      }
    } catch (_) {
      // Cleanup is best effort and never blocks opening a file.
    }
    return root;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final session in _sessions) {
      session.removeListener(_notify);
      unawaited(session.stop());
    }
    _sessions.clear();
    super.dispose();
  }
}
