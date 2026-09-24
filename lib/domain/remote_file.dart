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

abstract interface class RemoteFileSystem {
  Future<RemoteDirectory> browse(String path);
  String childPath(String directory, String name);
  Future<void> deleteFile(String path);
  Future<void> createDirectory(String path);
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
