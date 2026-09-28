// Run with `dart tool/download_benchmark.dart`. This measures only local
// streaming/write overhead, not SSH encryption, server latency or link speed.
import 'dart:io';
import 'dart:typed_data';

import 'package:harbor_ssh/data/download_stream.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

Future<void> main() async {
  const size = 32 * 1024 * 1024;
  final directory = await Directory.systemTemp.createTemp('harbor-transfer-');
  try {
    for (final buffered in [false, true]) {
      final path = File('${directory.path}/transfer.bin');
      final output = await path.open(mode: FileMode.write);
      var writes = 0;
      var lastProgress = 0;
      final timer = Stopwatch()..start();
      Stream<Uint8List> source() async* {
        final chunk = Uint8List(16 * 1024);
        for (var i = 0; i < chunk.length; i++) {
          chunk[i] = i % 251;
        }
        for (var offset = 0; offset < size; offset += chunk.length) {
          yield chunk;
        }
      }

      Future<void> write(Uint8List bytes) async {
        await output.writeFrom(bytes);
        writes++;
      }

      try {
        if (buffered) {
          await writeDownloadStream(
            source(),
            write,
            cancellation: TransferCancellation(),
            onProgress: (value) => lastProgress = value,
          );
        } else {
          await for (final chunk in source()) {
            await write(chunk);
            lastProgress += chunk.length;
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      timer.stop();
      if (await path.length() != size || lastProgress != size) {
        throw StateError('Incorrect transfer length or progress');
      }
      final bytes = await path.readAsBytes();
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != (i % (16 * 1024)) % 251) {
          throw StateError('Corrupt transfer at offset $i');
        }
      }
      final speed =
          size /
          (1024 * 1024) /
          (timer.elapsedMicroseconds / Duration.microsecondsPerSecond);
      stdout.writeln(
        '${buffered ? 'buffered' : 'baseline'}: '
        '${speed.toStringAsFixed(1)} MiB/s; '
        '${timer.elapsedMilliseconds} ms; $writes writes; bytes verified',
      );
      await path.delete();
    }
  } finally {
    final file = File('${directory.path}/transfer.bin');
    if (await file.exists()) await file.delete();
    await directory.delete();
  }
}
