import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/upload_stream.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

void main() {
  test('按块切分并写到各自偏移，内容与顺序完整', () async {
    final writes = <(int, List<int>)>[];
    final progress = <int>[];
    await writeUploadStream(
      Stream.fromIterable([
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List.fromList([6]),
      ]),
      (data, offset) async => writes.add((offset, data.toList())),
      offset: 10,
      cancellation: TransferCancellation(),
      onProgress: progress.add,
      chunkSize: 2,
    );
    expect(writes.map((write) => write.$1), [10, 12, 14, 15]);
    expect(writes.map((write) => write.$2), [
      [1, 2],
      [3, 4],
      [5],
      [6],
    ]);
    expect(progress, [12, 14, 15, 16]);
  });

  test('乱序应答时进度只推进到连续确认的末尾', () async {
    final replies = <Completer<void>>[];
    final progress = <int>[];
    final upload = writeUploadStream(
      Stream.value(Uint8List(6)),
      (_, _) {
        final reply = Completer<void>();
        replies.add(reply);
        return reply.future;
      },
      offset: 0,
      cancellation: TransferCancellation(),
      onProgress: progress.add,
      chunkSize: 2,
      maxPendingRequests: 3,
    );
    await pumpEventQueue();
    expect(replies, hasLength(3));
    replies[2].complete();
    replies[1].complete();
    await pumpEventQueue();
    expect(progress, isEmpty);
    replies[0].complete();
    await upload;
    expect(progress, [2, 4, 6]);
  });

  test('中间写入失败时进度停在失败块之前，后续成功不被计入', () async {
    final replies = <Completer<void>>[];
    final progress = <int>[];
    final upload = writeUploadStream(
      Stream.value(Uint8List(6)),
      (_, _) {
        final reply = Completer<void>();
        replies.add(reply);
        return reply.future;
      },
      offset: 0,
      cancellation: TransferCancellation(),
      onProgress: progress.add,
      chunkSize: 2,
      maxPendingRequests: 3,
    );
    await pumpEventQueue();
    replies[2].complete();
    replies[1].completeError(StateError('write failed'));
    replies[0].complete();
    await expectLater(upload, throwsStateError);
    expect(progress, [2]);
  });

  test('在途写入数受限，等待应答时不继续读取来源', () async {
    final replies = <Completer<void>>[];
    var produced = 0;
    Stream<Uint8List> source() async* {
      for (var i = 0; i < 10; i++) {
        produced++;
        yield Uint8List(1);
      }
    }

    final upload = writeUploadStream(
      source(),
      (_, _) {
        final reply = Completer<void>();
        replies.add(reply);
        return reply.future;
      },
      offset: 0,
      cancellation: TransferCancellation(),
      onProgress: (_) {},
      maxPendingRequests: 2,
    );
    await pumpEventQueue();
    expect(replies, hasLength(2));
    expect(produced, lessThanOrEqualTo(3));
    replies[0].complete();
    await pumpEventQueue();
    expect(replies, hasLength(3));
    while (replies.any((reply) => !reply.isCompleted)) {
      for (final reply in replies) {
        if (!reply.isCompleted) reply.complete();
      }
      await pumpEventQueue();
    }
    await upload;
    expect(replies, hasLength(10));
  });

  test('取消后不再发出新的写入，已发出的写入确认后计入进度', () async {
    final cancellation = TransferCancellation();
    final replies = <Completer<void>>[];
    final progress = <int>[];
    var settled = false;
    final upload = writeUploadStream(
      Stream.value(Uint8List(8)),
      (_, _) {
        final reply = Completer<void>();
        replies.add(reply);
        return reply.future;
      },
      offset: 0,
      cancellation: cancellation,
      onProgress: progress.add,
      chunkSize: 2,
      maxPendingRequests: 2,
    ).whenComplete(() => settled = true);
    await pumpEventQueue();
    expect(replies, hasLength(2));
    cancellation.cancel();
    replies[0].complete();
    await pumpEventQueue();
    // 已发出的第二个写入尚未应答，取消不会提前返回。
    expect(settled, isFalse);
    replies[1].complete();
    await expectLater(upload, throwsA(isA<TransferCancelled>()));
    expect(replies, hasLength(2));
    expect(progress, [2, 4]);
  });
}
