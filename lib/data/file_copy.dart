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
