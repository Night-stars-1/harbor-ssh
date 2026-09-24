import 'dart:async';
import 'dart:typed_data';

import '../domain/remote_file.dart';

/// Forward one chunk at a time. The destination acknowledges consumption before
/// the source reads more, so even SFTP-to-SFTP copies have bounded memory.
Future<void> copyFileBetween({
  required RemoteFileSystem source,
  required RemoteFileSystem destination,
  required String sourcePath,
  required String destinationPath,
  required TransferCancellation cancellation,
  required void Function(int) onProgress,
}) async {
  Stream<Uint8List> relay() async* {
    final chunks = StreamController<Uint8List>();
    Completer<void>? consumed;
    var stopped = false;
    final producer = source
        .download(
          sourcePath,
          (bytes) async {
            cancellation.check();
            if (stopped) throw TransferCancelled();
            final ack = Completer<void>();
            consumed = ack;
            chunks.add(bytes);
            await ack.future;
            if (stopped) throw TransferCancelled();
          },
          cancellation: cancellation,
          onProgress: (_) {},
        )
        .then(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!stopped) chunks.addError(error, stack);
          },
        )
        .whenComplete(() {
          unawaited(chunks.close());
        });
    try {
      await for (final bytes in chunks.stream) {
        yield bytes;
        if (consumed?.isCompleted == false) consumed!.complete();
      }
    } finally {
      stopped = true;
      if (consumed?.isCompleted == false) consumed!.complete();
      await producer;
    }
  }

  await destination.upload(
    destinationPath,
    relay(),
    cancellation: cancellation,
    onProgress: onProgress,
  );
}

final class DirectoryCopyResult {
  const DirectoryCopyResult({
    required this.files,
    required this.directories,
    required this.totalBytes,
  });

  final int files, directories;
  final int? totalBytes;
}

final class _DirectoryCopyEntry {
  const _DirectoryCopyEntry({
    required this.sourcePath,
    required this.destinationPath,
    required this.directory,
    this.size,
  });

  final String sourcePath, destinationPath;
  final bool directory;
  final int? size;
}

Future<DirectoryCopyResult> copyDirectoryBetween({
  required RemoteFileSystem source,
  required RemoteFileSystem destination,
  required String sourcePath,
  required String destinationPath,
  required TransferCancellation cancellation,
  required void Function(DirectoryCopyResult result) onPrepared,
  required void Function(int bytes) onProgress,
}) async {
  final entries = <_DirectoryCopyEntry>[];
  var files = 0, directories = 1, knownBytes = 0;
  var totalKnown = true;

  Future<void> plan(String sourceDirectory, String destinationDirectory) async {
    cancellation.check();
    final listing = await source.browse(sourceDirectory);
    for (final entry in listing.entries) {
      cancellation.check();
      if (entry.isLink) {
        throw StateError('文件夹中包含符号链接「${entry.name}」，无法安全复制');
      }
      final target = destination.childPath(destinationDirectory, entry.name);
      if (entry.isDirectory) {
        directories++;
        entries.add(
          _DirectoryCopyEntry(
            sourcePath: entry.path,
            destinationPath: target,
            directory: true,
          ),
        );
        await plan(entry.path, target);
      } else {
        files++;
        if (entry.size == null) {
          totalKnown = false;
        } else {
          knownBytes += entry.size!;
        }
        entries.add(
          _DirectoryCopyEntry(
            sourcePath: entry.path,
            destinationPath: target,
            directory: false,
            size: entry.size,
          ),
        );
      }
    }
  }

  await plan(sourcePath, destinationPath);
  final result = DirectoryCopyResult(
    files: files,
    directories: directories,
    totalBytes: totalKnown ? knownBytes : null,
  );
  onPrepared(result);
  cancellation.check();
  final createdDirectories = <String>[];
  final createdFiles = <String>[];
  try {
    await destination.createDirectory(destinationPath);
    createdDirectories.add(destinationPath);
    cancellation.check();
    var completedBytes = 0;
    for (final entry in entries) {
      cancellation.check();
      if (entry.directory) {
        await destination.createDirectory(entry.destinationPath);
        createdDirectories.add(entry.destinationPath);
        cancellation.check();
        continue;
      }
      var currentBytes = 0;
      await copyFileBetween(
        source: source,
        destination: destination,
        sourcePath: entry.sourcePath,
        destinationPath: entry.destinationPath,
        cancellation: cancellation,
        onProgress: (bytes) {
          currentBytes = bytes;
          onProgress(completedBytes + bytes);
        },
      );
      createdFiles.add(entry.destinationPath);
      completedBytes += currentBytes;
    }
    cancellation.check();
    return result;
  } catch (error, stack) {
    // Delete only entries created by this operation. If another process adds
    // content concurrently, non-recursive directory removal leaves it intact.
    for (final path in createdFiles.reversed) {
      try {
        await destination.deleteFile(path);
      } catch (_) {}
    }
    for (final path in createdDirectories.reversed) {
      try {
        await destination.deleteDirectory(path);
      } catch (_) {}
    }
    Error.throwWithStackTrace(error, stack);
  }
}
