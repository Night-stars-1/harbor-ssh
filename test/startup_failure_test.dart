import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/startup_failure.dart';

void main() {
  test('钥匙串错误只显示系统状态码，不泄露消息或详情', () {
    final message = describeStartupFailure(
      StartupStage.recovery,
      PlatformException(
        code: 'Unexpected security result code',
        message: 'private-key-password',
        details: -34018,
      ),
    );
    expect(message, contains('凭据与同步恢复'));
    expect(message, contains('-34018'));
    expect(message, contains('签名权限不兼容'));
    expect(message, isNot(contains('private-key-password')));
    expect(message, contains('请勿删除钥匙串记录'));
  });

  for (final entry in {
    -128: '授权已取消',
    -25293: '授权失败',
    -25308: '无法交互',
    -25291: '服务当前不可用',
    -9999: '无法读取钥匙串',
  }.entries) {
    test('钥匙串状态 ${entry.key} 显示恢复建议', () {
      final message = describeStartupFailure(
        StartupStage.recovery,
        PlatformException(
          code: 'Unexpected security result code',
          details: entry.key,
        ),
      );
      expect(message, contains(entry.value));
      expect(message, contains(entry.key.toString()));
    });
  }

  test('异常详情不是状态码时不输出原始内容', () {
    for (final error in [
      PlatformException(
        code: 'Unexpected security result code',
        message: 'secret-value',
        details: {'key': 'secret-value'},
      ),
      PlatformException(code: 'secret-value', message: 'secret-value'),
      const FormatException('secret-value', '{privateKey: secret-value}'),
      const FileSystemException('secret-value', '/secret-value'),
      StateError('secret-value'),
      MissingPluginException('secret-value'),
    ]) {
      expect(
        describeStartupFailure(StartupStage.hosts, error),
        isNot(contains('secret-value')),
      );
    }
  });

  test('配置格式错误与目录权限错误分别显示', () {
    expect(
      describeStartupFailure(
        StartupStage.users,
        const FormatException('bad JSON'),
      ),
      allOf(contains('用户配置'), contains('格式无法解析')),
    );
    expect(
      describeStartupFailure(
        StartupStage.localDirectory,
        const FileSystemException('denied'),
      ),
      allOf(contains('本地文件目录'), contains('访问权限')),
    );
  });
}
