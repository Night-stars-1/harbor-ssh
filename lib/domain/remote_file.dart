import 'dart:typed_data';

class RemoteFile {
  const RemoteFile({
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.isLink = false,
    this.size,
    this.modified,
  });
  final String name, path;
  final bool isDirectory, isLink;
  final int? size;
  final DateTime? modified;
}

class RemoteDirectory {
  const RemoteDirectory(this.path, this.entries);
  final String path;
  final List<RemoteFile> entries;
}

class TransferCancelled implements Exception {}

class TransferCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw TransferCancelled();
  }
}

/// Permissions a filesystem reports for one entry.
///
/// Each field holds exactly what the filesystem reported: a value it does not
/// report stays null, so "unknown" is never confused with 0 (or with a group
/// the caller merely assumed).
class FilePermissions {
  const FilePermissions({this.mode, this.userId, this.groupId});

  /// Permission and special bits (0..07777), without the file type bits.
  final int? mode;

  /// Numeric owner id. Never resolved to a name.
  final int? userId;

  /// Numeric group id. Never resolved to a name.
  final int? groupId;
}

abstract interface class RemoteFileSystem {
  Future<RemoteDirectory> browse(String path);
  String childPath(String directory, String name);
  Future<void> deleteFile(String path);
  Future<void> createDirectory(String path);

  /// Creates [path] only when nothing exists there yet. An entry that already
  /// has that name — file, directory or symlink — is never replaced, adopted
  /// or written through.
  Future<void> createFileExclusive(String path);
  Future<void> deleteDirectory(String path, {bool recursive = false});
  Future<void> renameExclusive(String oldPath, String newPath);
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  });
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  });
}

/// Range reads and metadata used to validate a transfer before resuming it.
///
/// [readRange], like [RemoteFileSystem.download], hands over every buffer it
/// passes to `write` and never reuses it: a pipelined upload keeps buffers
/// until the server acknowledges them.
abstract interface class ResumableSource {
  Future<RemoteFile> statFile(String path);
  Future<void> readRange(
    String path,
    Future<void> Function(Uint8List) write, {
    required int offset,
    int? length,
    required TransferCancellation cancellation,
  });
}

abstract interface class ResumableFileSystem
    implements RemoteFileSystem, ResumableSource {
  /// Discards an unacknowledged tail before writing at [offset]. Progress is
  /// the absolute acknowledged offset, never the number of queued bytes.
  Future<void> writeRange(
    String path,
    Stream<Uint8List> source, {
    required int offset,
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  });
}

/// A filesystem that can report and change the permissions of an entry.
///
/// Only a filesystem that can read permissions back implements this: callers
/// must offer permission editing only for tabs whose [RemoteFileSystem] does,
/// so a filesystem without the capability is never given a write it cannot
/// confirm.
abstract interface class RemoteFilePermissions implements RemoteFileSystem {
  /// What the filesystem reports for [path] right now. A symlink is never
  /// followed, so a link reports the link itself.
  Future<FilePermissions> readPermissions(String path);

  /// Applies [mode] (0..07777, special bits preserved), [userId] and [groupId]
  /// (numeric, always together) or both, then reads the result back. A change
  /// the filesystem does not confirm — including one it does not report at
  /// all — is a failure, never a reported success. Symlinks are refused, and
  /// so is a path whose type is not reported, since neither can be written
  /// safely.
  Future<void> setPermissions(
    String path, {
    int? mode,
    int? userId,
    int? groupId,
  });
}

String remoteChild(String directory, String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\x00')) {
    throw const FormatException('无效的文件名');
  }
  return '${directory == '/' ? '' : directory}/$name';
}

String remoteParent(String path) {
  final index = path.lastIndexOf('/');
  return index <= 0 ? '/' : path.substring(0, index);
}

String fileSizeLabel(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}
