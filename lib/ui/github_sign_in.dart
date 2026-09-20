import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/github_device_auth.dart';
import '../data/sync_config.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';

class GitHubSignIn extends StatefulWidget {
  const GitHubSignIn({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onBusyChanged,
    this.authFactory,
    this.openBrowser,
  });
  final SyncSettingsController controller;
  final bool enabled;
  final ValueChanged<bool> onBusyChanged;
  final GitHubDeviceAuth Function()? authFactory;
  final Future<bool> Function(Uri)? openBrowser;
  @override
  State<GitHubSignIn> createState() => _GitHubSignInState();
}

class _GitHubSignInState extends State<GitHubSignIn> {
  GitHubDeviceAuth? _auth;
  GitHubDeviceCode? _code;
  bool _signingOut = false;

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _openPage(GitHubDeviceCode code) async {
    try {
      final opened =
          await (widget.openBrowser?.call(code.verificationUri) ??
              launchUrl(
                code.verificationUri,
                mode: LaunchMode.externalApplication,
              ));
      if (!opened) {
        throw const SyncFailure('无法打开浏览器，请访问 github.com/login/device');
      }
    } catch (_) {
      if (mounted) {
        showSettingsNotice(
          context,
          '无法打开浏览器，请访问 github.com/login/device',
          error: true,
        );
      }
    }
  }

  Future<void> _signIn() async {
    if (_auth != null || !widget.enabled || _signingOut) return;
    final auth = (widget.authFactory ?? GitHubDeviceAuth.new)();
    setState(() => _auth = auth);
    widget.onBusyChanged(true);
    try {
      final code = await auth.start();
      if (!mounted) return;
      setState(() => _code = code);
      await _openPage(code);
      final account = await auth.waitForAuthorization(code);
      if (!mounted) return;
      await widget.controller.saveGitHubAccount(account.token, account.login);
      if (mounted) showSettingsNotice(context, '已登录 GitHub：${account.login}');
    } on GitHubAuthCancelled {
      // Cancellation and leaving the page never replace existing credentials.
    } catch (error) {
      if (mounted) {
        showSettingsNotice(
          context,
          error is SyncFailure ? error.message : 'GitHub 登录未完成，请重试',
          error: true,
        );
      }
    } finally {
      auth.cancel();
      if (mounted) {
        setState(() {
          _auth = null;
          _code = null;
        });
        widget.onBusyChanged(false);
      }
    }
  }

  Future<void> _signOut() async {
    if (_auth != null || !widget.enabled || _signingOut) return;
    setState(() => _signingOut = true);
    widget.onBusyChanged(true);
    try {
      await widget.controller.saveGitHubAccount('', '');
      if (mounted) showSettingsNotice(context, '已退出 GitHub 登录');
    } catch (error) {
      if (mounted) {
        showSettingsNotice(
          context,
          error is SyncFailure ? error.message : '退出登录失败，请重试',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _signingOut = false);
        widget.onBusyChanged(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final config = widget.controller.settings;
      final signedIn = config?.token.isNotEmpty == true;
      final login = config?.githubLogin ?? '';
      final code = _code;
      final busy = _auth != null || _signingOut || !widget.enabled;
      return Column(
        children: [
          SettingsRow(
            title: 'GitHub 账号',
            description: signedIn ? (login.isEmpty ? '已登录' : '@$login') : '未登录',
            control: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (signedIn)
                  TextButton(
                    onPressed: busy ? null : _signOut,
                    child: Text(_signingOut ? '退出中…' : '退出登录'),
                  ),
                FilledButton.tonalIcon(
                  key: const ValueKey('github-sign-in'),
                  onPressed: busy ? null : _signIn,
                  icon: const Icon(Icons.open_in_browser_rounded, size: 20),
                  label: Text(
                    _auth != null
                        ? '等待授权…'
                        : signedIn
                        ? '重新登录'
                        : '网页登录',
                  ),
                ),
              ],
            ),
          ),
          if (code != null)
            SettingsRow(
              title: '验证码',
              description: '在 GitHub 网页输入验证码并确认授权',
              control: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    code.userCode,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(letterSpacing: 2),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        onPressed: () async {
                          try {
                            await Clipboard.setData(
                              ClipboardData(text: code.userCode),
                            );
                            if (context.mounted) {
                              showSettingsNotice(context, '验证码已复制');
                            }
                          } catch (_) {
                            if (context.mounted) {
                              showSettingsNotice(
                                context,
                                '无法复制，请手动输入验证码',
                                error: true,
                              );
                            }
                          }
                        },
                        child: const Text('复制验证码'),
                      ),
                      TextButton(
                        onPressed: () => _openPage(code),
                        child: const Text('打开网页'),
                      ),
                      TextButton(
                        onPressed: () => _auth?.cancel(),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else if (_auth != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 8),
                child: TextButton(
                  onPressed: () => _auth?.cancel(),
                  child: const Text('取消'),
                ),
              ),
            ),
        ],
      );
    },
  );
}
