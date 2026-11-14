import 'dart:math';
import 'dart:typed_data';

import '../domain/remote_file.dart';

/// Publishes [content] at [path] without ever truncating the original in
/// place.
///
/// The content is uploaded to an exclusive temporary file, [verify] runs to
/// reject external modification, then the original is moved to a temporary
/// backup and the staged file is published with a rename. Any failure restores
/// the original (or, when the backup itself cannot be moved back, reports its
/// path) and removes the staged file. Cancelling before the publish leaves the
/// original untouched.
///
/// Returns the backup path that could not be deleted after a successful
/// publish; it still holds the previous contents for manual recovery.
Future<String?> replaceRemoteFile(
  RemoteFileSystem files,
  String path,
  Stream<Uint8List> content, {
  required Future<void> Function() verify,
  TransferCancellation? cancellation,
  void Function(int bytes)? onProgress,
}) async {
  final directory = remoteParent(path);
  final stagingPath = files.childPath(directory, _temporaryName('incoming'));
  final backupPath = files.childPath(directory, _temporaryName('backup'));

  var backupMoveAttempted = false, backupMoved = false, published = false;
  try {
    cancellation?.check();
    await files.upload(
      stagingPath,
      content,
      cancellation: cancellation ?? TransferCancellation(),
      onProgress: onProgress ?? (_) {},
    );

    cancellation?.check();
    await verify();

    cancellation?.check();
    backupMoveAttempted = true;
    await files.renameExclusive(path, backupPath);
    backupMoved = true;

    cancellation?.check();
    await files.renameExclusive(stagingPath, path);
    published = true;

    try {
      await files.deleteFile(backupPath);
      return null;
    } catch (_) {
      return backupPath;
    }
  } catch (error, stack) {
    var restoreFailed = false;
    if (backupMoveAttempted && !published) {
      try {
        await files.renameExclusive(backupPath, path);
      } catch (_) {
        if (backupMoved) restoreFailed = true;
      }
    }
    var stageCleanupFailed = false;
    if (!published) {
      stageCleanupFailed = !await _removeIfExists(files, stagingPath);
    }
    if (restoreFailed) {
      throw StateError('保存失败，原文件保留在临时备份中：$backupPath');
    }
    if (stageCleanupFailed) {
      throw StateError('保存失败，临时文件未能清理：$stagingPath');
    }
    Error.throwWithStackTrace(error, stack);
  }
}

/// The entry currently listed at [path], or null when nothing is there.
Future<RemoteFile?> statRemoteEntry(RemoteFileSystem files, String path) async {
  final listing = await files.browse(remoteParent(path));
  final name = path.split('/').last;
  for (final entry in listing.entries) {
    if (entry.path == path || entry.name == name) return entry;
  }
  return null;
}

Future<bool> _removeIfExists(RemoteFileSystem files, String path) async {
  try {
    await files.deleteFile(path);
    return true;
  } catch (_) {
    try {
      return await statRemoteEntry(files, path) == null;
    } catch (_) {
      return false;
    }
  }
}

String _temporaryName(String kind) {
  final random = Random.secure();
  final token = List.generate(
    4,
    (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
  ).join();
  return '.harbor-$kind-$token';
}
