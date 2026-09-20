import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/remote_file.dart';

/// Each operation owns its channel, independently of the terminal/completion.
class SftpFiles implements RemoteFileSystem {
  SftpFiles(this.openChannel);
  final Future<SftpClient> Function() openChannel;
  static const _timeout = Duration(seconds: 20);

  Future<T> _run<T>(Future<T> Function(SftpClient) action) async {
    final opening = openChannel();
    late SftpClient client;
    try {
      client = await opening.timeout(_timeout);
    } on TimeoutException {
      unawaited(
        opening
            .then((lateClient) => lateClient.close())
            .catchError((Object _) {}),
      );
      rethrow;
    }
    try {
      return await action(client);
    } finally {
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  @override
  Future<RemoteDirectory> browse(String path) => _run((client) async {
    if (path == '~' || path.startsWith('~/')) {
      final home = await client.absolute('.').timeout(_timeout);
      path = '$home${path.substring(1)}';
    }
    final absolute = await client.absolute(path).timeout(_timeout);
    final names = await client.listdir(absolute).timeout(_timeout);
    final entries = <RemoteFile>[];
    for (final name in names) {
      if (name.filename == '.' ||
          name.filename == '..' ||
          name.filename.contains('/') ||
          name.filename.contains('\x00')) {
        continue;
      }
      final fullPath = remoteChild(absolute, name.filename);
      var attrs = name.attr;
      if (attrs.isSymbolicLink) {
        try {
          attrs = await client.stat(fullPath).timeout(_timeout);
        } catch (_) {}
      }
      entries.add(
        RemoteFile(
          name: name.filename,
          path: fullPath,
          isDirectory: attrs.isDirectory,
          isLink: name.attr.isSymbolicLink,
          size: attrs.size,
          modified: attrs.modifyTime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return RemoteDirectory(absolute, entries);
  });

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) => _run((client) async {
    cancellation.check();
    // Exclusive creation also prevents overwriting symlinks or a file that
    // appeared after the directory listing was loaded.
    SftpFile? file;
    var complete = false;
    try {
      file = await client
          .open(
            path,
            mode:
                SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive,
          )
          .timeout(_timeout);
      var offset = 0;
      await for (final chunk in source.timeout(_timeout)) {
        cancellation.check();
        await file.writeBytes(chunk, offset: offset).timeout(_timeout);
        offset += chunk.length;
        onProgress(offset);
      }
      cancellation.check();
      await file.close().timeout(_timeout);
      complete = true;
    } finally {
      if (file != null && !complete) {
        try {
          await file.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await client.remove(path).timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  });

  @override
  Future<void> deleteFile(String path) =>
      _run((client) => client.remove(path).timeout(_timeout));

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) => _run((client) async {
    cancellation.check();
    final file = await client.open(path).timeout(_timeout);
    try {
      var count = 0;
      await for (final chunk in file.read().timeout(_timeout)) {
        cancellation.check();
        await write(chunk);
        count += chunk.length;
        onProgress(count);
      }
      cancellation.check();
    } finally {
      try {
        await file.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  });
}
