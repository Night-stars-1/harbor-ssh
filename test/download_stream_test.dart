import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/download_stream.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

void main() {
  test('合并小块并保留大块、尾块的数据顺序', () async {
    final written = <List<int>>[];
    final progress = <int>[];
    await writeDownloadStream(
      Stream.fromIterable([
        Uint8List.fromList([0, 1]),
        Uint8List(0),
        Uint8List.fromList([2, 3, 4, 5, 6, 7, 8, 9, 10]),
      ]),
      (bytes) async => written.add(bytes.toList()),
      cancellation: TransferCancellation(),
      onProgress: progress.add,
      bufferSize: 4,
    );
    expect(written, [
      [0, 1, 2, 3],
      [4, 5, 6, 7],
      [8, 9, 10],
    ]);
    expect(progress, [4, 8, 11]);
  });

  test('空文件不产生虚假进度或写入', () async {
    await writeDownloadStream(
      const Stream.empty(),
      (_) async => fail('空文件不应写入数据块'),
      cancellation: TransferCancellation(),
      onProgress: (_) => fail('空文件不应产生进度'),
    );
  });

  test('缓冲区持有自己的数据，源复用数据块也不损坏内容', () async {
    Stream<Uint8List> source() async* {
      final reused = Uint8List(2);
      for (var value = 0; value < 3; value++) {
        reused.fillRange(0, reused.length, value);
        yield reused;
      }
    }

    final output = <int>[];
    await writeDownloadStream(
      source(),
      (bytes) async => output.addAll(bytes),
      cancellation: TransferCancellation(),
      onProgress: (_) {},
      bufferSize: 8,
    );
    expect(output, [0, 0, 1, 1, 2, 2]);
  });

  test('慢目标施加背压，等待写入时不读取后续数据或修改当前缓冲区', () async {
    final writing = Completer<void>();
    final release = Completer<void>();
    var produced = 0;
    var writes = 0;
    Stream<Uint8List> source() async* {
      for (var value = 0; value < 12; value++) {
        produced++;
        yield Uint8List.fromList([value]);
      }
    }

    final pending = writeDownloadStream(
      source(),
      (bytes) async {
        writes++;
        if (writes == 1) {
          writing.complete();
          await release.future;
          expect(bytes, [0, 1, 2, 3]);
        }
      },
      cancellation: TransferCancellation(),
      onProgress: (_) {},
      bufferSize: 4,
    );
    await writing.future;
    expect(produced, 4);
    expect(writes, 1);
    release.complete();
    await pending;
    expect(produced, 12);
    expect(writes, 3);
  });

  test('取消后不提交未满缓冲区，也不读取后续数据', () async {
    final cancellation = TransferCancellation();
    Stream<Uint8List> source() async* {
      yield Uint8List.fromList([1, 2]);
      cancellation.cancel();
      yield Uint8List.fromList([3, 4]);
      fail('取消后不应继续读取');
    }

    await expectLater(
      writeDownloadStream(
        source(),
        (_) async => fail('取消后不应写入'),
        cancellation: cancellation,
        onProgress: (_) => fail('取消后不应报告进度'),
        bufferSize: 8,
      ),
      throwsA(isA<TransferCancelled>()),
    );
  });

  test('写入失败会结束来源并且不报告成功进度', () async {
    var closed = false;
    Stream<Uint8List> source() async* {
      try {
        yield Uint8List.fromList([1, 2, 3, 4]);
        fail('目标失败后不应继续读取');
      } finally {
        closed = true;
      }
    }

    await expectLater(
      writeDownloadStream(
        source(),
        (_) async => throw StateError('disk full'),
        cancellation: TransferCancellation(),
        onProgress: (_) => fail('失败写入不能报告进度'),
        bufferSize: 4,
      ),
      throwsStateError,
    );
    expect(closed, isTrue);
  });

  test('来源失败不会提交残留缓冲区', () async {
    final output = <int>[];
    final progress = <int>[];
    Stream<Uint8List> source() async* {
      yield Uint8List.fromList([0, 1, 2, 3, 4, 5]);
      throw StateError('disconnected');
    }

    await expectLater(
      writeDownloadStream(
        source(),
        (bytes) async => output.addAll(bytes),
        cancellation: TransferCancellation(),
        onProgress: progress.add,
        bufferSize: 4,
      ),
      throwsStateError,
    );
    expect(output, [0, 1, 2, 3]);
    expect(progress, [4]);
  });

  test('写入进度回调取消后立即停止，不提交下一块', () async {
    final cancellation = TransferCancellation();
    final output = <int>[];
    await expectLater(
      writeDownloadStream(
        Stream.value(Uint8List.fromList([0, 1, 2, 3, 4, 5])),
        (bytes) async => output.addAll(bytes),
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
        bufferSize: 4,
      ),
      throwsA(isA<TransferCancelled>()),
    );
    expect(output, [0, 1, 2, 3]);
  });

  test('预先取消和无效缓冲区大小不读取来源', () async {
    Stream<Uint8List> source() async* {
      fail('不应读取来源');
    }

    await expectLater(
      writeDownloadStream(
        source(),
        (_) async {},
        cancellation: TransferCancellation()..cancel(),
        onProgress: (_) {},
      ),
      throwsA(isA<TransferCancelled>()),
    );
    await expectLater(
      writeDownloadStream(
        source(),
        (_) async {},
        cancellation: TransferCancellation(),
        onProgress: (_) {},
        bufferSize: 0,
      ),
      throwsArgumentError,
    );
  });
}
