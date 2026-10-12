import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/app_update.dart';
import 'package:harbor_ssh/domain/app_update.dart';

void main() {
  test('版本比较忽略前缀和构建号，缺省位视为 0', () {
    expect(isNewerAppVersion('v1.0.26', '1.0.25'), isTrue);
    expect(isNewerAppVersion('1.0.25', '1.0.25+26'), isFalse);
    expect(isNewerAppVersion('1.1', '1.0.99'), isTrue);
    expect(isNewerAppVersion('1.1', '1.1.0'), isFalse);
    expect(isNewerAppVersion('1.0.10', '1.0.9'), isTrue);
    expect(isNewerAppVersion('1.0.9', '1.0.10'), isFalse);
    expect(isNewerAppVersion('nightly', '1.0.0'), isFalse);
    expect(isNewerAppVersion('2.0.0', ''), isFalse);
  });

  group('GitHub Release', () {
    late HttpServer server;
    late Map<String, Object?> release;
    late List<int> package;
    var status = 200;
    var downloads = 0;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      package = List.generate(70000, (i) => i * 7 % 251);
      final digest = const DartSha256()
          .hashSync(package)
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      status = 200;
      downloads = 0;
      String asset(String name) => 'http://127.0.0.1:${server.port}/$name';
      release = {
        'tag_name': 'v9.1.0',
        'html_url': 'https://github.com/$appRepository/releases/tag/v9.1.0',
        'published_at': '2026-10-11T16:19:26Z',
        'body': '## 新功能\n\n- 应用内更新',
        'assets': [
          for (final name in [
            'harbor-ssh-windows-setup.exe',
            'harbor-ssh-android-armeabi-v7a.apk',
            'harbor-ssh-android-arm64-v8a.apk',
          ])
            {
              'name': name,
              'state': 'uploaded',
              'size': package.length,
              'digest': 'sha256:$digest',
              'browser_download_url': asset(name),
            },
        ],
      };
      server.listen((request) async {
        if (request.uri.path == '/repos/$appRepository/releases/latest') {
          expect(request.headers.value('user-agent'), 'Harbor-SSH');
          request.response.statusCode = status;
          request.response.write(jsonEncode(release));
        } else {
          downloads++;
          request.response.add(package);
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    AppUpdater updater(
      TargetPlatform platform, {
      List<String> abis = const [],
      bool installerManaged = true,
      Directory? directory,
    }) => AppUpdater(
      apiBase: Uri.parse('http://127.0.0.1:${server.port}/'),
      platform: platform,
      installedVersion: () async => '1.0.25',
      androidAbis: () async => abis,
      installerManaged: installerManaged,
      downloadDirectory: () async => directory ?? Directory.systemTemp,
    );

    test('按平台和首选 ABI 选择安装包', () async {
      final windows = await updater(TargetPlatform.windows).check();
      expect(windows.available, isTrue);
      expect(windows.current, '1.0.25');
      expect(windows.release.version, '9.1.0');
      expect(windows.release.asset!.name, 'harbor-ssh-windows-setup.exe');

      final android = await updater(
        TargetPlatform.android,
        abis: ['x86', 'armeabi-v7a', 'arm64-v8a'],
      ).latest();
      expect(android.asset!.name, 'harbor-ssh-android-armeabi-v7a.apk');

      // A portable folder or a missing package falls back to the release page.
      expect(
        (await updater(
          TargetPlatform.windows,
          installerManaged: false,
        ).latest()).asset,
        isNull,
      );
      expect((await updater(TargetPlatform.macOS).latest()).asset, isNull);
    });

    test('拒绝无效版本号和限流响应', () async {
      release['tag_name'] = 'latest';
      await expectLater(
        updater(TargetPlatform.windows).latest(),
        throwsA(isA<UpdateFailure>()),
      );
      status = 403;
      await expectLater(
        updater(TargetPlatform.windows).latest(),
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.message,
            'message',
            contains('频繁'),
          ),
        ),
      );
    });

    test('下载校验 SHA-256，失败时不留下文件', () async {
      final directory = await Directory.systemTemp.createTemp('harbor-update');
      addTearDown(() => directory.delete(recursive: true));
      final client = updater(TargetPlatform.windows, directory: directory);
      final asset = (await client.latest()).asset!;
      final progress = <int>[];
      final file = await client.download(
        asset,
        onProgress: (received, total) {
          expect(total, package.length);
          progress.add(received);
        },
      );
      expect(await file.readAsBytes(), package);
      expect(progress.last, package.length);

      final tampered = ReleaseAsset(
        name: 'tampered.exe',
        url: asset.url,
        size: asset.size,
        sha256: '0' * 64,
      );
      await expectLater(
        client.download(tampered),
        throwsA(
          isA<UpdateFailure>().having(
            (e) => e.message,
            'message',
            '安装包校验失败，已删除',
          ),
        ),
      );
      final short = ReleaseAsset(
        name: 'short.exe',
        url: asset.url,
        size: asset.size + 1,
      );
      await expectLater(client.download(short), throwsA(isA<UpdateFailure>()));
      final left = await directory
          .list(recursive: true)
          .map((entry) => entry.path.split(Platform.pathSeparator).last)
          .where((name) => name.contains('.'))
          .toList();
      expect(left, ['harbor-ssh-windows-setup.exe']);
      expect(downloads, 3);
    });
  });
}
