import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/local_transfer.dart';

void main() {
  test('流式落盘、空文件、取消清理及同名文件保护', () async {
    final directory = await Directory.systemTemp.createTemp(
      'harbor-sftp-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final download = await NativeLocalTransfer.createDiskDownload(
      directory.path,
      'report.bin',
    );
    await download.write(Uint8List.fromList([1, 2]));
    await download.write(Uint8List.fromList([3, 4]));
    expect(await File('${directory.path}/report.bin').exists(), isFalse);
    await download.finish();
    expect(await File('${directory.path}/report.bin').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    await expectLater(
      NativeLocalTransfer.createDiskDownload(directory.path, 'report.bin'),
      throwsA(isA<FileSystemException>()),
    );
    final empty = await NativeLocalTransfer.createDiskDownload(
      directory.path,
      'empty',
    );
    await empty.finish();
    expect(await File('${directory.path}/empty').length(), 0);
    final cancelled = await NativeLocalTransfer.createDiskDownload(
      directory.path,
      'cancelled',
    );
    await cancelled.write(Uint8List.fromList([9]));
    await cancelled.abort();
    expect(await File('${directory.path}/cancelled').exists(), isFalse);
    final race = await NativeLocalTransfer.createDiskDownload(
      directory.path,
      'race',
    );
    await race.write(Uint8List.fromList([8]));
    final existing = await File('${directory.path}/race').writeAsString('keep');
    await expectLater(race.finish(), throwsA(isA<FileSystemException>()));
    await race.abort();
    expect(await existing.readAsString(), 'keep');
    expect(
      await directory.list().where((item) => item is Directory).toList(),
      isEmpty,
    );
  });
  test('远端名称转换为安全的本地文件名', () {
    expect(localFileName('../CON:thing?'), '.._CON_thing_');
    expect(localFileName('NUL.txt'), '_NUL.txt');
    expect(localFileName('...'), 'download');
    expect(localFileName('文件.txt'), '文件.txt');
  });
}
