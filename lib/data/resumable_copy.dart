import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../domain/remote_file.dart';

String transferTemporaryName() {
  final random = Random.secure();
  return '.harbor-part-${List.generate(4, (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')).join()}';
}

abstract interface class ResumableCopy {
  int get transferred;
  int? get total;
  bool get complete;
  void rebind(ResumableSource source, ResumableFileSystem destination);
  Future<void> run(
    TransferCancellation cancellation,
    void Function(int) onProgress,
  );
  Future<void> discard();
}

/// Owns a private staging file. Only acknowledged writes advance the offset;
/// retries open fresh SFTP channels and truncate any uncertain tail first.
/// The final filename is published exclusively after size/source validation.
class ResumableFileCopy implements ResumableCopy {
  ResumableFileCopy({
    required this.source,
    required this.destination,
    required this.sourcePath,
    required this.destinationPath,
  }) : stagingPath = destination.childPath(
         remoteParent(destinationPath),
         transferTemporaryName(),
       );

  ResumableSource source;
  ResumableFileSystem destination;
  final String sourcePath, destinationPath, stagingPath;
  RemoteFile? _snapshot;
  Uint8List? _head, _tail;
  bool _created = false;
  @override
  bool complete = false;
  @override
  int transferred = 0;
  @override
  int? get total => _snapshot?.size;

  @override
  void rebind(ResumableSource source, ResumableFileSystem destination) {
    this.source = source;
    this.destination = destination;
  }

  Future<Uint8List> _sample(
    ResumableSource files,
    String path,
    int offset,
    int length,
    TransferCancellation cancellation,
  ) async {
    final bytes = BytesBuilder(copy: true);
    await files.readRange(
      path,
      (chunk) async {
        bytes.add(chunk);
      },
      offset: offset,
      length: length,
      cancellation: cancellation,
    );
    return bytes.takeBytes();
  }

  bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _checkSource() async {
    final current = await source.statFile(sourcePath);
    if (current.size != _snapshot!.size ||
        current.modified != _snapshot!.modified) {
      throw StateError('源文件已变化，请放弃本次传输后重新开始');
    }
  }

  @override
  Future<void> run(
    TransferCancellation cancellation,
    void Function(int) onProgress,
  ) async {
    if (complete) return;
    cancellation.check();
    if (_snapshot == null) {
      final attrs = await source.statFile(sourcePath);
      if (attrs.size == null ||
          attrs.size! < 0 ||
          attrs.isDirectory ||
          attrs.isLink) {
        throw StateError('文件大小未知或不是普通文件，无法安全续传');
      }
      // Some virtual files advertise zero despite returning data. Never turn
      // them into a silently successful empty download.
      if (attrs.size == 0 &&
          (await _sample(source, sourcePath, 0, 1, cancellation)).isNotEmpty) {
        throw StateError('服务器未报告实际文件大小，无法安全续传');
      }
      _head = await _sample(
        source,
        sourcePath,
        0,
        min(32768, attrs.size!),
        cancellation,
      );
      _snapshot = attrs;
    }
    await _checkSource();
    if (!_equal(
      _head!,
      await _sample(source, sourcePath, 0, _head!.length, cancellation),
    )) {
      throw StateError('源文件已变化，请放弃本次传输后重新开始');
    }
    if (!_created) {
      await destination.createFileExclusive(stagingPath);
      _created = true;
    } else {
      final partial = await destination.statFile(stagingPath);
      if (partial.size == null || partial.size! < transferred) {
        throw StateError('传输缓存已变化，请放弃本次传输后重新开始');
      }
      if (transferred > 0) {
        final headLength = min(transferred, _head!.length);
        final head = await _sample(
          destination,
          stagingPath,
          0,
          headLength,
          cancellation,
        );
        final tailOffset = transferred - _tail!.length;
        final tail = await _sample(
          destination,
          stagingPath,
          tailOffset,
          _tail!.length,
          cancellation,
        );
        final sourceTail = await _sample(
          source,
          sourcePath,
          tailOffset,
          _tail!.length,
          cancellation,
        );
        if (!_equal(head, Uint8List.sublistView(_head!, 0, headLength)) ||
            !_equal(tail, _tail!) ||
            !_equal(sourceTail, _tail!)) {
          throw StateError('源文件或传输缓存已变化，请放弃本次传输后重新开始');
        }
      }
    }
    onProgress(transferred);
    // Writes are pipelined, so the acknowledged offset trails what was read.
    // Chunks stay queued until they can no longer hold part of the final
    // [_tailSize] bytes before that offset; the tail is built once afterwards.
    final sent = Queue<(int, Uint8List)>();
    final startOffset = transferred;
    var readOffset = transferred;
    Stream<Uint8List> relay() async* {
      final chunks = StreamController<Uint8List>();
      Completer<void>? consumed;
      var stopped = false;
      final producer = source
          .readRange(
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
            offset: transferred,
            length: total! - transferred,
            cancellation: cancellation,
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
          // The source reuses nothing it hands over, so keeping the view is safe.
          sent.add((readOffset, bytes));
          readOffset += bytes.length;
          yield bytes;
          if (consumed?.isCompleted == false) consumed!.complete();
        }
      } finally {
        stopped = true;
        if (consumed?.isCompleted == false) consumed!.complete();
        await producer;
      }
    }

    try {
      await destination.writeRange(
        stagingPath,
        relay(),
        offset: transferred,
        cancellation: cancellation,
        onProgress: (bytes) {
          transferred = bytes;
          while (sent.length > 1 && sent.elementAt(1).$1 <= bytes - _tailSize) {
            sent.removeFirst();
          }
          onProgress(bytes);
        },
      );
    } finally {
      if (transferred > startOffset) _tail = _tailOf(sent, transferred);
    }

    cancellation.check();
    await _checkSource();
    if (transferred != total ||
        (await destination.statFile(stagingPath)).size != total) {
      throw StateError('文件传输不完整，请继续传输');
    }
    await destination.renameExclusive(stagingPath, destinationPath);
    complete = true;
  }

  @override
  Future<void> discard() async {
    if (!_created || complete) return;
    final entries = (await destination.browse(remoteParent(stagingPath)))
        .entries;
    if (entries.any((entry) => entry.path == stagingPath)) {
      await destination.deleteFile(stagingPath);
    }
    _created = false;
    transferred = 0;
    _snapshot = null;
    _head = _tail = null;
  }

  static const _tailSize = 32768;

  /// Copies the last [_tailSize] bytes before [end] out of [sent], which holds
  /// contiguous `(offset, bytes)` chunks covering them.
  static Uint8List _tailOf(Queue<(int, Uint8List)> sent, int end) {
    final start = max(sent.first.$1, end - _tailSize);
    final tail = Uint8List(end - start);
    for (final (offset, bytes) in sent) {
      final from = max(start, offset), to = min(end, offset + bytes.length);
      if (from < to) {
        tail.setRange(from - start, to - start, bytes, from - offset);
      }
    }
    return tail;
  }
}

/// Keeps completed children while a directory copy is paused. The private root
/// becomes visible under the requested name only when every child is complete.
class ResumableDirectoryCopy implements ResumableCopy {
  ResumableDirectoryCopy({
    required this.source,
    required this.destination,
    required this.sourcePath,
    required this.destinationPath,
  }) : stagingPath = destination.childPath(
         remoteParent(destinationPath),
         transferTemporaryName(),
       );
  ResumableFileSystem source, destination;
  final String sourcePath, destinationPath, stagingPath;
  final _files = <ResumableFileCopy>[];
  final _directories = <String>[];
  final _createdDirectories = <String>[];
  final _listings = <String, List<RemoteFile>>{};
  final _removedFiles = <String>{};
  bool _planned = false;
  @override
  bool complete = false;
  @override
  int get transferred =>
      _files.fold(0, (bytes, file) => bytes + file.transferred);
  @override
  int? total;

  @override
  void rebind(ResumableSource source, ResumableFileSystem destination) {
    this.source = source as ResumableFileSystem;
    this.destination = destination;
    for (final file in _files) {
      file.rebind(source, destination);
    }
  }

  Future<void> _plan(
    String path,
    String target,
    TransferCancellation cancellation,
  ) async {
    cancellation.check();
    final entries = (await source.browse(path)).entries;
    _listings[path] = entries;
    _directories.add(target);
    for (final entry in entries) {
      if (entry.isLink) throw StateError('文件夹中包含符号链接「${entry.name}」，无法安全复制');
      final next = destination.childPath(target, entry.name);
      if (entry.isDirectory) {
        await _plan(entry.path, next, cancellation);
      } else {
        _files.add(
          ResumableFileCopy(
            source: source,
            destination: destination,
            sourcePath: entry.path,
            destinationPath: next,
          ),
        );
      }
    }
  }

  Future<void> _validate(TransferCancellation cancellation) async {
    for (final snapshot in _listings.entries) {
      cancellation.check();
      final current = (await source.browse(snapshot.key)).entries;
      final previous = {for (final entry in snapshot.value) entry.name: entry};
      if (current.length != previous.length ||
          current.any((entry) {
            final old = previous[entry.name];
            return old == null ||
                old.isLink != entry.isLink ||
                old.isDirectory != entry.isDirectory ||
                (!entry.isDirectory &&
                    (old.size != entry.size || old.modified != entry.modified));
          })) {
        throw StateError('源文件夹已变化，请放弃本次传输后重新开始');
      }
    }
  }

  @override
  Future<void> run(
    TransferCancellation cancellation,
    void Function(int) onProgress,
  ) async {
    if (complete) return;
    if (!_planned) {
      _files.clear();
      _directories.clear();
      _listings.clear();
      await _plan(sourcePath, stagingPath, cancellation);
      total = _listings.values
          .expand((entries) => entries)
          .where((entry) => !entry.isDirectory)
          .fold<int>(0, (bytes, entry) {
            if (entry.size == null) throw StateError('文件大小未知，无法安全续传');
            return bytes + entry.size!;
          });
      _planned = true;
    }
    await _validate(cancellation);
    for (final path in _directories.skip(_createdDirectories.length)) {
      cancellation.check();
      await destination.createDirectory(path);
      _createdDirectories.add(path);
    }
    onProgress(transferred);
    for (final file in _files) {
      cancellation.check();
      await file.run(cancellation, (_) => onProgress(transferred));
    }
    await _validate(cancellation);
    cancellation.check();
    await destination.renameExclusive(stagingPath, destinationPath);
    complete = true;
  }

  @override
  Future<void> discard() async {
    if (complete) return;
    for (final file in _files.reversed) {
      if (file.complete) {
        if (_removedFiles.contains(file.destinationPath)) continue;
        await destination.deleteFile(file.destinationPath);
        _removedFiles.add(file.destinationPath);
      } else {
        await file.discard();
      }
    }
    while (_createdDirectories.isNotEmpty) {
      await destination.deleteDirectory(_createdDirectories.last);
      _createdDirectories.removeLast();
    }
    _createdDirectories.clear();
  }
}
