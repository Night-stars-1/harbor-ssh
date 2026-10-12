import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/app_update.dart';

const appRepository = 'Night-stars-1/harbor-ssh';
const appUpdateChannel = MethodChannel('dev.harborssh/app_update');

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });
  final String name;
  final Uri url;
  final int size;

  /// Lowercase hex digest published by GitHub; older assets have none.
  final String? sha256;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.notes,
    required this.page,
    this.publishedAt,
    this.asset,
  });
  final String version, notes;
  final Uri page;
  final DateTime? publishedAt;

  /// Installer for this device, or null when this build updates through the
  /// release page (portable Windows folders, unknown platforms).
  final ReleaseAsset? asset;
}

class UpdateCheck {
  const UpdateCheck({required this.current, required this.release});
  final String current;
  final AppRelease release;
  bool get available => isNewerAppVersion(release.version, current);
}

/// Checks GitHub Releases and installs the matching package for this device.
///
/// One instance serves one check-and-download flow; [cancel] aborts it.
class AppUpdater {
  AppUpdater({
    Uri? apiBase,
    TargetPlatform? platform,
    this.installedVersion,
    this.androidAbis,
    this.downloadDirectory,
    this.installerManaged,
  }) : _apiBase = apiBase ?? Uri.https('api.github.com', '/'),
       _platform = platform ?? defaultTargetPlatform;

  final Uri _apiBase;
  final TargetPlatform _platform;
  final Future<String> Function()? installedVersion;
  final Future<List<String>> Function()? androidAbis;
  final Future<Directory> Function()? downloadDirectory;
  final bool? installerManaged;
  HttpClient? _activeClient;
  bool _cancelled = false;

  static const _maxReleaseBytes = 1024 * 1024;
  static const _maxPackageBytes = 512 * 1024 * 1024;

  TargetPlatform get platform => _platform;

  Future<String> currentVersion() async {
    try {
      return await (installedVersion?.call() ??
          PackageInfo.fromPlatform().then((info) => info.version));
    } catch (_) {
      throw const UpdateFailure('无法读取当前版本');
    }
  }

  /// Installed version together with the latest published release.
  Future<UpdateCheck> check() async {
    final current = await currentVersion();
    return UpdateCheck(current: current, release: await latest());
  }

  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
  }

  void _checkCancelled() {
    if (_cancelled) throw const UpdateCancelled();
  }

  Future<AppRelease> latest() async {
    _checkCancelled();
    final Map<String, dynamic> data;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    _activeClient = client;
    try {
      data = await (() async {
        final request = await client.getUrl(
          _apiBase.resolve('repos/$appRepository/releases/latest'),
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'Harbor-SSH');
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw UpdateFailure(switch (response.statusCode) {
            404 => '暂无已发布的版本',
            403 || 429 => 'GitHub 请求过于频繁，请稍后再试',
            _ => '检查更新失败（${response.statusCode}）',
          });
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > _maxReleaseBytes) {
            throw const UpdateFailure('版本信息过大');
          }
          bytes.add(chunk);
        }
        return Map<String, dynamic>.from(
          jsonDecode(utf8.decode(bytes.takeBytes())) as Map,
        );
      })().timeout(const Duration(seconds: 30));
    } on UpdateFailure {
      _checkCancelled();
      rethrow;
    } catch (error) {
      _checkCancelled();
      if (error is TimeoutException) {
        throw const UpdateFailure('检查更新超时，请检查网络后重试');
      }
      if (error is FormatException || error is TypeError) {
        throw const UpdateFailure('GitHub 返回了无效的版本信息');
      }
      throw const UpdateFailure('无法连接 GitHub，请检查网络后重试');
    } finally {
      client.close(force: true);
      _activeClient = null;
    }
    final tag = data['tag_name'];
    final page = Uri.tryParse(data['html_url'] as String? ?? '');
    if (tag is! String ||
        parseAppVersion(tag) == null ||
        page == null ||
        page.scheme != 'https') {
      throw const UpdateFailure('GitHub 返回了无效的版本信息');
    }
    final assets = data['assets'];
    final wanted = await _assetName();
    ReleaseAsset? asset;
    if (wanted != null && assets is List) {
      for (final item in assets) {
        if (item is! Map || item['name'] != wanted) continue;
        asset = _parseAsset(item);
        break;
      }
    }
    return AppRelease(
      version: tag.replaceFirst(RegExp('^[vV]'), ''),
      notes: (data['body'] as String? ?? '').trim(),
      page: page,
      publishedAt: DateTime.tryParse(data['published_at'] as String? ?? ''),
      asset: asset,
    );
  }

  /// Packages must use the API's scheme: HTTPS against GitHub, plain HTTP only
  /// for a local test server.
  ReleaseAsset? _parseAsset(Map<dynamic, dynamic> item) {
    final url = Uri.tryParse(item['browser_download_url'] as String? ?? '');
    final size = item['size'];
    if (url == null ||
        url.scheme != _apiBase.scheme ||
        size is! int ||
        size <= 0 ||
        size > _maxPackageBytes ||
        item['state'] != 'uploaded') {
      return null;
    }
    final digest = item['digest'];
    String? sha256;
    if (digest is String && digest.startsWith('sha256:')) {
      sha256 = digest.substring(7).toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
    }
    return ReleaseAsset(
      name: item['name'] as String,
      url: url,
      size: size,
      sha256: sha256,
    );
  }

  Future<String?> _assetName() async {
    switch (_platform) {
      case TargetPlatform.windows:
        // Only installer-managed copies can be replaced in place; a portable
        // folder would gain a second installation instead.
        final managed =
            installerManaged ??
            File(
              '${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.pathSeparator}unins000.exe',
            ).existsSync();
        return managed ? 'harbor-ssh-windows-setup.exe' : null;
      case TargetPlatform.macOS:
        return 'harbor-ssh-macos.dmg';
      case TargetPlatform.android:
        final abis =
            await (androidAbis?.call() ??
                appUpdateChannel
                    .invokeListMethod<String>('abis')
                    .then((value) => value ?? const <String>[]));
        const published = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
        for (final abi in abis) {
          if (published.contains(abi)) return 'harbor-ssh-android-$abi.apk';
        }
        return null;
      default:
        return null;
    }
  }

  /// Downloads [asset] and verifies its size and published SHA-256.
  Future<File> download(
    ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    _checkCancelled();
    final root = await (downloadDirectory?.call() ?? getTemporaryDirectory());
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}harbor-update',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${asset.name}',
    );
    final partial = File('${file.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    _activeClient = client;
    IOSink? sink;
    try {
      final request = await client.getUrl(asset.url);
      request.headers.set(HttpHeaders.userAgentHeader, 'Harbor-SSH');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw UpdateFailure('下载失败（${response.statusCode}）');
      }
      final hash = const DartSha256().newHashSink();
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > asset.size) {
          throw const UpdateFailure('安装包大小与发布信息不一致');
        }
        hash.add(chunk);
        sink.add(chunk);
        onProgress?.call(received, asset.size);
      }
      await sink.close();
      sink = null;
      if (received != asset.size) {
        throw const UpdateFailure('下载不完整，请重试');
      }
      hash.close();
      final digest = (await hash.hash()).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (asset.sha256 != null && digest != asset.sha256) {
        throw const UpdateFailure('安装包校验失败，已删除');
      }
      if (await file.exists()) await file.delete();
      return await partial.rename(file.path);
    } catch (error) {
      await sink?.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
      _checkCancelled();
      if (error is UpdateFailure) rethrow;
      if (error is TimeoutException) {
        throw const UpdateFailure('下载超时，请检查网络后重试');
      }
      throw const UpdateFailure('下载失败，请检查网络后重试');
    } finally {
      client.close(force: true);
      _activeClient = null;
    }
  }

  /// Hands [package] to the platform installer.
  ///
  /// Windows runs the Inno Setup installer silently and quits so it can
  /// replace the files; the installer relaunches Harbor SSH afterwards.
  Future<void> install(File package) async {
    switch (_platform) {
      case TargetPlatform.windows:
        await Process.start(package.path, [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/RELAUNCH=1',
        ], mode: ProcessStartMode.detached);
        exit(0);
      case TargetPlatform.macOS:
        // The sandbox lets Launch Services mount the image for the user.
        if (!await launchUrl(Uri.file(package.path))) {
          throw const UpdateFailure('无法打开安装包');
        }
      case TargetPlatform.android:
        try {
          await appUpdateChannel.invokeMethod<void>('install', package.path);
        } on PlatformException catch (error) {
          throw UpdateFailure(
            error.code == 'permission_denied'
                ? '未允许安装未知应用，请在系统设置中允许后重试'
                : '无法打开系统安装程序',
          );
        }
      default:
        throw const UpdateFailure('当前平台不支持应用内安装');
    }
  }
}
