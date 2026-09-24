import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'local_path_access.dart';
import '../domain/remote_file.dart';
import 'local_transfer.dart';

/// A local folder uses the same streaming operations as SFTP.
class LocalFiles implements RemoteFileSystem {
  LocalFiles(String root)
    : root = Directory(root).absolute.path.replaceAll('\\', '/');
  static String? _preparedHomePath;

  static Future<void> prepareDefaultHome({
    Future<Directory> Function()? directoryProvider,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    if (directoryProvider == null) {
      _preparedHomePath = null;
      return;
    }
    try {
      _preparedHomePath = (await directoryProvider()).path;
    } catch (_) {
      _preparedHomePath = null;
    }
  }

  final String root;

  static Future<String> validateDefaultPath(String value) async {
    final path = value.trim();
    if (path.isEmpty) return '';
    final absolute = Platform.isWindows
        ? RegExp(r'^(?:[A-Za-z]:[/\\]|[/\\]{2}[^/\\]+[/\\][^/\\]+)')
              .hasMatch(path)
        : path.startsWith('/');
    if (!absolute) throw const FileSystemException('请填写完整的本地目录路径');
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw const FileSystemException('目录不存在，请选择已有文件夹');
    }
    try {
      await directory.list(followLinks: false).take(1).drain<void>();
    } on FileSystemException {
      throw const FileSystemException('无法读取这个目录，请检查访问权限');
    }
    return directory.absolute.path.replaceAll('\\', '/');
  }

  static Future<String> restoreDefaultPath(String value) async {
    final saved = value.trim();
    if (saved.isEmpty) return '';
    if (Platform.isMacOS) {
      try {
        final restored = await LocalPathAccess.restore(saved);
        if (restored != null) return await validateDefaultPath(restored);
      } on FileSystemException {
        // A stale bookmark is cleared by the platform and falls back below.
      }
    }
    final candidates = <String>{
      ...localDefaultPathCandidates(saved),
      if (Platform.isWindows &&
          saved.replaceAll('\\', '/').toLowerCase().endsWith('/my documents') &&
          _preparedHomePath?.isNotEmpty == true)
        _preparedHomePath!,
    };
    for (final candidate in candidates) {
      try {
        return await validateDefaultPath(candidate);
      } on FileSystemException {
        // Try the next migration candidate, then fall back to a safe default.
      }
    }
    return '';
  }

  static LocalFiles? userHome() {
    if (Platform.isWindows || Platform.isMacOS) {
      final prepared = _preparedHomePath;
      if (prepared != null && prepared.isNotEmpty) return LocalFiles(prepared);
      if (Platform.isMacOS) return null;
    }
    if (!Platform.isWindows && !Platform.isLinux) return null;
    final path =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    return path == null || path.isEmpty ? null : LocalFiles(path);
  }

  static Future<LocalFiles> defaultHome() async {
    final desktopHome = userHome();
    if (desktopHome != null) return desktopHome;
    // Mobile apps browse their writable documents directory without a picker.
    return LocalFiles((await getApplicationDocumentsDirectory()).path);
  }

  @override
  Future<RemoteDirectory> browse(String path) async {
    final directory = Directory(path == '~' ? root : path).absolute;
    final entries = <RemoteFile>[];
    await for (final entity in directory.list(followLinks: false)) {
      final fullPath = entity.path.replaceAll('\\', '/');
      final attrs = await FileStat.stat(entity.path);
      if (attrs.type == FileSystemEntityType.notFound) continue;
      entries.add(
        RemoteFile(
          name: fullPath.split('/').last,
          path: fullPath,
          isDirectory: attrs.type == FileSystemEntityType.directory,
          isLink: entity is Link,
          size: attrs.size,
          modified: attrs.modified,
        ),
      );
    }
    entries.sort(
      (a, b) => a.isDirectory != b.isDirectory
          ? (a.isDirectory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return RemoteDirectory(directory.path.replaceAll('\\', '/'), entries);
  }

  @override
  Future<void> deleteFile(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw const FileSystemException('只能删除文件');
    }
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    var count = 0;
    await for (final bytes in File(path).openRead()) {
      cancellation.check();
      await write(Uint8List.fromList(bytes));
      count += bytes.length;
      onProgress(count);
    }
    cancellation.check();
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    cancellation.check();
    final target = await NativeLocalTransfer.createDiskDownload(
      File(path).parent.path,
      path.split('/').last,
    );
    var finished = false;
    try {
      var count = 0;
      await for (final bytes in source) {
        cancellation.check();
        await target.write(bytes);
        count += bytes.length;
        onProgress(count);
      }
      cancellation.check();
      await target.finish();
      finished = true;
    } finally {
      if (!finished) await target.abort();
    }
  }
}

List<String> localDefaultPathCandidates(String value, {bool? windows}) {
  var normalized = value.trim().replaceAll('\\', '/');
  if (RegExp(r'^/+$').hasMatch(normalized)) {
    normalized = '/';
  } else {
    final driveRoot = RegExp(r'^([A-Za-z]:)/+$').firstMatch(normalized);
    normalized = driveRoot != null
        ? '${driveRoot.group(1)}/'
        : normalized.replaceFirst(RegExp(r'/+$'), '');
  }
  if (!(windows ?? Platform.isWindows)) return [normalized];
  final slash = normalized.lastIndexOf('/');
  final name = slash < 0 ? normalized : normalized.substring(slash + 1);
  if (name.toLowerCase() != 'my documents') return [normalized];
  final parent = slash < 0 ? '' : normalized.substring(0, slash);
  return ['${parent.isEmpty ? '' : '$parent/'}Documents', normalized];
}
