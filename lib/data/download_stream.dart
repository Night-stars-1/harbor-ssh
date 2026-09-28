import 'dart:typed_data';

import '../domain/remote_file.dart';

/// Coalesce small network replies into bounded sequential writes. The writer
/// must finish consuming each buffer before its future completes, as required
/// by [RemoteFileSystem.download]. No whole-file buffering is involved.
Future<void> writeDownloadStream(
  Stream<Uint8List> source,
  Future<void> Function(Uint8List) write, {
  required TransferCancellation cancellation,
  required void Function(int bytes) onProgress,
  int bufferSize = 256 * 1024,
}) async {
  if (bufferSize <= 0) {
    throw ArgumentError.value(bufferSize, 'bufferSize', 'must be positive');
  }
  cancellation.check();
  final buffer = Uint8List(bufferSize);
  var buffered = 0;
  var written = 0;

  Future<void> flush() async {
    cancellation.check();
    if (buffered == 0) return;
    await write(Uint8List.sublistView(buffer, 0, buffered));
    written += buffered;
    buffered = 0;
    onProgress(written);
    cancellation.check();
  }

  await for (final chunk in source) {
    cancellation.check();
    var offset = 0;
    while (offset < chunk.length) {
      final available = bufferSize - buffered;
      final remaining = chunk.length - offset;
      final count = remaining < available ? remaining : available;
      buffer.setRange(buffered, buffered + count, chunk, offset);
      buffered += count;
      offset += count;
      if (buffered == bufferSize) await flush();
    }
  }
  await flush();
}
