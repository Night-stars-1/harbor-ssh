import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/github_device_auth.dart';
import '../data/sync_config.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';
import 'theme.dart';

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
  bool _codeCopied = false;
  bool _cancelRequested = false;

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

  Future<void> _copyCode(
    GitHubDeviceCode code, {
    bool automatic = false,
  }) async {
    try {
      await Clipboard.setData(ClipboardData(text: code.userCode));
      if (mounted && !_cancelRequested && identical(_code, code)) {
        setState(() => _codeCopied = true);
        if (!automatic) showSettingsNotice(context, '验证码已复制');
      }
    } catch (_) {
      if (mounted && !_cancelRequested && identical(_code, code)) {
        setState(() => _codeCopied = false);
        showSettingsNotice(context, '无法复制，请手动输入验证码', error: true);
      }
    }
  }

  void _cancelSignIn() {
    _cancelRequested = true;
    _auth?.cancel();
  }

  Future<void> _signIn() async {
    if (_auth != null || !widget.enabled || _signingOut) return;
    final auth = (widget.authFactory ?? GitHubDeviceAuth.new)();
    setState(() {
      _auth = auth;
      _cancelRequested = false;
      _codeCopied = false;
    });
    widget.onBusyChanged(true);
    try {
      final code = await auth.start();
      if (!mounted || _cancelRequested) return;
      setState(() => _code = code);
      await _copyCode(code, automatic: true);
      if (!mounted || _cancelRequested) return;
      await _openPage(code);
      final account = await auth.waitForAuthorization(code);
      if (!mounted || _cancelRequested) return;
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
      if (code != null) return _authorizationPanel(context, code);
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
          if (_auth != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 8),
                child: TextButton(
                  onPressed: _cancelSignIn,
                  child: const Text('取消'),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _authorizationPanel(BuildContext context, GitHubDeviceCode code) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '在 GitHub 完成登录',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              TextButton(onPressed: _cancelSignIn, child: const Text('取消')),
            ],
          ),
          Text(
            _codeCopied ? '验证码已复制，在网页中粘贴并授权' : '在网页中输入验证码并授权',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final codeField = Material(
                color: colors.secondaryContainer,
                shape: HarborShapes.superellipse(
                  const BorderRadius.all(Radius.circular(16)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          code.userCode,
                          style: theme.textTheme.titleLarge?.copyWith(
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700,
                            color: colors.onSecondaryContainer,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('github-copy-code'),
                        onPressed: () => _copyCode(code),
                        icon: const Icon(
                          Icons.content_copy_rounded,
                          size: 20,
                          semanticLabel: '复制验证码',
                        ),
                        color: colors.onSecondaryContainer,
                      ),
                    ],
                  ),
                ),
              );
              final openButton = FilledButton.tonalIcon(
                onPressed: () => _openPage(code),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('打开 GitHub'),
              );
              final wide =
                  constraints.maxWidth >= 480 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 20;
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: codeField),
                    const SizedBox(width: 12),
                    openButton,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  codeField,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: openButton),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
