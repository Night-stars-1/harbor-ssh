import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../domain/remote_file.dart';

/// Pipeline [source] into positional writes starting at [offset]. Up to
/// [maxPendingRequests] writes of at most [chunkSize] bytes are in flight, so a
/// link is not limited to one chunk per round trip. [onProgress] only reports
/// the end of the contiguous acknowledged prefix: a failed or unanswered write
/// is never skipped over, which keeps resume checkpoints exact.
Future<void> writeUploadStream(
  Stream<Uint8List> source,
  Future<void> Function(Uint8List data, int offset) write, {
  required int offset,
  required TransferCancellation cancellation,
  required void Function(int bytes) onProgress,
  Duration? timeout,
  int chunkSize = 32 * 1024,
  int maxPendingRequests = 64,
}) async {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  if (maxPendingRequests <= 0) {
    throw ArgumentError.value(
      maxPendingRequests,
      'maxPendingRequests',
      'must be positive',
    );
  }
  // Every reply is observed immediately, so a write that fails behind the one
  // being awaited never becomes an unhandled error.
  final pending = Queue<(int, Future<(Object, StackTrace)?>)>();
  // Set once a write fails or stalls: nothing after it is contiguous.
  var broken = false;

  Future<void> settleFirst() async {
    final (end, reply) = pending.removeFirst();
    try {
      final failure = await (timeout == null ? reply : reply.timeout(timeout));
      if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
      onProgress(end);
    } catch (_) {
      broken = true;
      rethrow;
    }
  }

  try {
    var next = offset;
    await for (final chunk in source) {
      for (var start = 0; start < chunk.length; start += chunkSize) {
        if (pending.length >= maxPendingRequests) await settleFirst();
        cancellation.check();
        final piece = Uint8List.sublistView(
          chunk,
          start,
          min(start + chunkSize, chunk.length),
        );
        pending.add((
          next + piece.length,
          write(piece, next).then<(Object, StackTrace)?>(
            (_) => null,
            onError: (Object error, StackTrace stack) => (error, stack),
          ),
        ));
        next += piece.length;
      }
    }
    while (pending.isNotEmpty) {
      await settleFirst();
    }
  } catch (_) {
    // A cancelled or failed source still lets the writes already sent finish,
    // so the reported checkpoint covers everything the server acknowledged.
    while (pending.isNotEmpty && !broken) {
      try {
        await settleFirst();
      } catch (_) {}
    }
    rethrow;
  }
}
