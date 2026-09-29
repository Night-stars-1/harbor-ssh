import 'dart:io';

import 'package:flutter/services.dart';

enum StartupStage {
  recovery('凭据与同步恢复'),
  hosts('主机配置'),
  users('用户配置'),
  localDirectory('本地文件目录');

  const StartupStage(this.label);
  final String label;
}

/// Never expose exception messages/details: they can contain saved JSON, paths,
/// passwords or private keys. Only known categories and numeric codes are safe.
String describeStartupFailure(StartupStage stage, Object error) {
  final prefix = '启动失败：${stage.label}。';
  if (error is PlatformException &&
      error.code == 'Unexpected security result code') {
    final status = error.details is int ? error.details as int : null;
    final hint = switch (status) {
      -128 => '钥匙串授权已取消，请允许 Harbor SSH 访问原有凭据后重试。',
      -25293 => '钥匙串授权失败，请在“钥匙串访问”中检查 Harbor SSH 的访问权限后重试。',
      -25308 => '钥匙串当前无法交互，请解锁登录钥匙串并允许访问后重试。',
      -34018 => '钥匙串查询或应用签名权限不兼容，请反馈此错误码。',
      -25291 => '钥匙串服务当前不可用，请解锁登录钥匙串后重试。',
      _ => '无法读取钥匙串，请检查钥匙串授权后重试。',
    };
    return '$prefix\n$hint${status == null ? '' : '（错误码：$status）'}'
        '\n读取失败不代表数据已丢失，请勿删除钥匙串记录或重置配置。';
  }
  if (error is FormatException || error is TypeError) {
    return '$prefix\n保存的数据格式无法解析，原数据已保留。请勿重置配置。';
  }
  if (error is FileSystemException) {
    return '$prefix\n无法访问文件或目录，请检查该目录的访问权限后重试。';
  }
  if (error is PlatformException || error is MissingPluginException) {
    return '$prefix\n系统存储接口调用失败，请重启应用后重试。';
  }
  return '$prefix\n请重试，并反馈以上失败阶段。请勿重置配置。';
}
