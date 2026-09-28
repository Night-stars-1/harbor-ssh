import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/transfer_speed.dart';

void main() {
  testWidgets('速率使用实际间隔，停顿后衰减为零', (tester) async {
    var elapsed = Duration.zero;
    final speed = TransferSpeed(elapsed: () => elapsed);
    addTearDown(speed.dispose);
    speed.start();
    expect(speed.label, '0 B/s');
    speed.update(1024 * 1024);
    elapsed = const Duration(seconds: 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(speed.bytesPerSecond, 1024 * 1024);
    expect(speed.label, '1.0 MB/s');
    speed.update(2 * 1024 * 1024);
    elapsed = const Duration(seconds: 2);
    await tester.pump(const Duration(milliseconds: 250));
    expect(speed.label, '1.0 MB/s');
    elapsed = const Duration(seconds: 3);
    await tester.pump(const Duration(milliseconds: 250));
    expect(speed.label, '512 KB/s');
    elapsed = const Duration(seconds: 4);
    await tester.pump(const Duration(milliseconds: 250));
    expect(speed.label, '0 B/s');
    speed.stop();
  });

  testWidgets('下一个文件重新计时，单位随速度变化', (tester) async {
    var elapsed = Duration.zero;
    final speed = TransferSpeed(elapsed: () => elapsed);
    addTearDown(speed.dispose);
    for (final value in <int, String>{
      512: '512 B/s',
      1536: '1.5 KB/s',
      20 * 1024 * 1024: '20 MB/s',
      3 * 1024 * 1024 * 1024: '3.0 GB/s',
      0: '0 B/s',
    }.entries) {
      speed.start();
      expect(speed.bytesPerSecond, 0);
      speed.update(value.key);
      elapsed += const Duration(seconds: 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(speed.label, value.value);
    }
    speed.stop();
  });

  testWidgets('高频进度只更新计数，停止或释放后不再刷新', (tester) async {
    var elapsed = Duration.zero, updates = 0;
    final speed = TransferSpeed(elapsed: () => elapsed);
    speed.addListener(() => updates++);
    speed.start();
    for (var bytes = 0; bytes <= 10000; bytes++) {
      speed.update(bytes);
    }
    speed.update(-1);
    speed.update(1);
    expect(updates, 0);
    elapsed = const Duration(seconds: 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(updates, 1);
    expect(speed.bytesPerSecond, 10000);
    speed.stop();
    speed.update(20000);
    elapsed = const Duration(seconds: 5);
    await tester.pump(const Duration(seconds: 3));
    expect(updates, 1);
    speed.reset();
    expect(speed.label, '0 B/s');
    speed.dispose();
    speed.start();
    await tester.pump(const Duration(seconds: 3));
    expect(updates, 1);
  });
}
