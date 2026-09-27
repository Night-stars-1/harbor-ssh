import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/key_file.dart';
import '../data/ssh_keys.dart';
import '../domain/host.dart';
import 'expressive_widgets.dart';
import 'settings_widgets.dart';
import 'theme.dart';

typedef SaveHost = Future<void> Function(Host host, Credentials? stored);
typedef TestHost = Future<void> Function(Host host, Credentials credentials);

class HostEditor extends StatefulWidget {
  const HostEditor({
    super.key,
    this.host,
    this.credentials,
    this.users = const [],
    this.userCredentials = const {},
    required this.onSave,
    required this.onTest,
  });
  final Host? host;
  final Credentials? credentials;
  final List<SshUser> users;
  final Map<String, Credentials> userCredentials;
  final SaveHost onSave;
  final TestHost onTest;
  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.host?.name);
  late final _address = TextEditingController(text: widget.host?.address);
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  final _tags = <String>[];
  final _tagInput = TextEditingController();
  late final _username = TextEditingController(
    text: widget.host?.username ?? 'root',
  );
  late final _password = TextEditingController(
    text:
        widget.credentials?.password ??
        widget.userCredentials[widget.host?.userId]?.password,
  );
  late AuthMethod _auth = widget.host?.authMethod ?? AuthMethod.password;
  bool _passwordVisible = false;
  late final _users = widget.users
      .where((user) => user.authMethod == AuthMethod.privateKey)
      .toList();
  late final _userCredentials = {...widget.userCredentials};
  late String _userId = widget.host?.userId ?? '';
  late final String _id =
      widget.host?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
  bool _saving = false, _testing = false;
  bool get _busy => _saving || _testing;
  String? _error;
  Timer? _noticeTimer;
  OverlayEntry? _notice;
  @override
  void initState() {
    super.initState();
    _tags.addAll(widget.host?.tags ?? const []);
    if (_userId.isNotEmpty && _users.every((user) => user.id != _userId)) {
      _userId = '';
    }
    if (_auth == AuthMethod.password) _userId = '';
  }

  @override
  void dispose() {
    _dismissNotice();
    for (final controller in [
      _name,
      _address,
      _port,
      _tagInput,
      _username,
      _password,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Shows [_noticeDuration]-long feedback above everything else on screen.
  ///
  /// A dialog lives in the navigator overlay, so a snack bar bound to the
  /// scaffold underneath would render behind it. The notice is therefore
  /// inserted at the top of that same overlay and ignores pointers, keeping the
  /// dialog usable while it fades away.
  void _showNotice(String message) {
    _dismissNotice();
    final bottom = MediaQuery.paddingOf(context).bottom;
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 16,
        right: 16,
        bottom: bottom + 16,
        child: IgnorePointer(
          child: Semantics(
            liveRegion: true,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: expressiveDuration(context),
              curve: expressiveCurve,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - value)),
                  child: child,
                ),
              ),
              child: SettingsNotice(message: message),
            ),
          ),
        ),
      ),
    );
    _notice = entry;
    Overlay.of(context).insert(entry);
    _noticeTimer = Timer(_noticeDuration, _dismissNotice);
  }

  void _dismissNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notice?.remove();
    _notice = null;
  }

  static const _noticeDuration = Duration(seconds: 3);

  SshUser? get _selectedUser =>
      _users.where((user) => user.id == _userId).firstOrNull;

  Credentials? get _connectionCredentials => _auth == AuthMethod.password
      ? (_password.text.isEmpty ? null : Credentials(password: _password.text))
      : _userCredentials[_userId];

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  /// 加入 [raw] 标签：去首尾空白，忽略空值与重复项，不按空格拆分。
  void _addTag(String raw) {
    if (_busy) return;
    final value = raw.trim();
    if (value.isEmpty) return;
    _tagInput.clear();
    if (_tags.contains(value)) return;
    setState(() => _tags.add(value));
  }

  void _removeTag(String tag) {
    if (_busy) return;
    setState(() => _tags.remove(tag));
  }

  /// 保存/测试所用的标签列表，含尚未按“添加”的非空输入。
  List<String> _collectTags() {
    final pending = _tagInput.text.trim();
    return [
      ..._tags,
      if (pending.isNotEmpty && !_tags.contains(pending)) pending,
    ];
  }

  Future<void> _submit({required bool test}) async {
    if (_busy) return;
    if (!_form.currentState!.validate()) return;
    final credentials = _connectionCredentials;
    if (test &&
        (credentials == null ||
            (_auth == AuthMethod.privateKey &&
                credentials.privateKey.trim().isEmpty))) {
      setState(
        () => _error = _auth == AuthMethod.password
            ? '请输入密码后测试连接。'
            : '请先在凭证页补全所选凭证的私钥。',
      );
      return;
    }
    setState(() {
      _saving = !test;
      _testing = test;
      _error = null;
    });
    final host = Host(
      id: _id,
      name: _name.text.trim(),
      address: _address.text.trim(),
      port: int.parse(_port.text),
      username: _username.text.trim(),
      tags: _collectTags(),
      authMethod: _auth,
      favorite: widget.host?.favorite ?? false,
      userId: _auth == AuthMethod.privateKey ? _userId : '',
    );
    try {
      if (test) {
        await widget.onTest(host, credentials!);
        if (mounted) _showNotice('连接成功，SSH 身份验证已通过。');
      } else {
        await widget.onSave(
          host,
          _auth == AuthMethod.password ? credentials : null,
        );
        if (mounted) Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = test ? '测试连接失败：$error' : '保存失败，请检查系统安全存储及文件权限，然后重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _testing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      insetPadding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 20 : 28,
          ),
          child: Form(
            key: _form,
            onChanged: () {
              if (!_busy && _error != null) {
                setState(() => _error = null);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExpressiveMark(
                      size: 44,
                      icon: Icons.dns_outlined,
                      flower: true,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.host == null ? '新建连接' : '编辑连接',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      tooltip: '取消',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '连接名称',
                    hintText: '例如：生产服务器',
                  ),
                  validator: _required,
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final address = TextFormField(
                      controller: _address,
                      enabled: !_busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '主机地址',
                        hintText: 'IP 或域名',
                      ),
                      validator: (value) {
                        if (_required(value) != null) return '请填写主机地址';
                        if (RegExp(r'\s|/|@|\[|\]').hasMatch(value!.trim())) {
                          return '请输入裸 IP 或域名，不含协议前缀';
                        }
                        return null;
                      },
                    );
                    final port = TextFormField(
                      controller: _port,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '端口'),
                      validator: (value) {
                        final port = int.tryParse(value ?? '');
                        return port == null || port < 1 || port > 65535
                            ? '1–65535'
                            : null;
                      },
                    );
                    if (constraints.maxWidth < 380 ||
                        MediaQuery.textScalerOf(context).scale(16) > 20) {
                      return Column(
                        children: [address, const SizedBox(height: 16), port],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: address),
                        const SizedBox(width: 12),
                        SizedBox(width: 110, child: port),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _tagInput,
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      // 默认的 onEditingComplete 会在回车后让输入框失焦，
                      // 覆盖成空实现以便连续添加多个标签。
                      onEditingComplete: () {},
                      onFieldSubmitted: _addTag,
                      decoration: InputDecoration(
                        labelText: '标签（可选）',
                        hintText: '按回车或点右侧按钮添加，例如：生产环境',
                        suffixIcon: IconButton(
                          tooltip: '添加标签',
                          onPressed: _busy
                              ? null
                              : () => _addTag(_tagInput.text),
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ),
                    ),
                    if (_tags.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final tag in _tags)
                            _TagPill(
                              tag: tag,
                              onDeleted: _busy
                                  ? null
                                  : () => _removeTag(tag),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _username,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: '用户名'),
                  autocorrect: false,
                  validator: _required,
                ),
                const SizedBox(height: 16),
                if (_auth == AuthMethod.password)
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: !_passwordVisible,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: '密码',
                      suffixIcon: IconButton(
                        tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _passwordVisible = !_passwordVisible,
                              ),
                        icon: Icon(
                          _passwordVisible
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                if (_auth == AuthMethod.password) const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final colors = Theme.of(context).colorScheme;
                    DropdownMenuEntry<String> entry(String id, String name) {
                      final selected = id == _userId;
                      return DropdownMenuEntry(
                        value: id,
                        label: name,
                        trailingIcon: selected
                            ? const Icon(Icons.check_rounded, size: 20)
                            : null,
                        style: MenuItemButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          backgroundColor: selected
                              ? colors.secondaryContainer
                              : null,
                          foregroundColor: selected
                              ? colors.onSecondaryContainer
                              : colors.onSurface,
                          textStyle: Theme.of(context).textTheme.bodyLarge,
                        ),
                      );
                    }

                    return DropdownMenuFormField<String>(
                      key: ValueKey(_userId),
                      initialSelection: _selectedUser?.id,
                      width: constraints.maxWidth,
                      menuHeight: 320,
                      enabled: !_busy,
                      selectOnly: true,
                      requestFocusOnTap: true,
                      enableSearch: false,
                      textStyle: Theme.of(context).textTheme.bodyLarge,
                      inputDecorationTheme: Theme.of(context)
                          .inputDecorationTheme,
                      label: const Text('凭证（可选）'),
                      alignmentOffset: const Offset(0, 4),
                      menuStyle: MenuStyle(
                        backgroundColor: WidgetStatePropertyAll(
                          colors.surfaceContainer,
                        ),
                        surfaceTintColor: const WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        elevation: const WidgetStatePropertyAll(2),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.all(8),
                        ),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                      dropdownMenuEntries: [
                        entry('', '不使用凭证'),
                        for (final user in _users) entry(user.id, user.name),
                      ],
                      onSelected: (value) => setState(() {
                        _userId = value ?? '';
                        _auth = _userId.isEmpty
                            ? AuthMethod.password
                            : AuthMethod.privateKey;
                        _error = null;
                      }),
                      validator: (_) =>
                          _auth == AuthMethod.privateKey &&
                              _selectedUser == null
                          ? '请选择已有凭证'
                          : null,
                    );
                  },
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _submit(test: true),
                        icon: _testing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded, size: 18),
                        label: Text(_testing ? '正在测试…' : '测试连接'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _submit(test: false),
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_rounded, size: 18),
                        label: const Text('保存连接'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 已添加标签的胶囊：标签文字可换行，长标签在窄屏上不会溢出。
///
/// 不用 [InputChip] 是因为它把标签固定成单行（内部 `maxLines: 1` 且
/// `softWrap: false`），长标签会被淡出截断而读不全。
class _TagPill extends StatelessWidget {
  const _TagPill({required this.tag, required this.onDeleted});
  final String tag;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = theme.chipTheme;
    final labelStyle = chip.labelStyle ?? theme.textTheme.labelLarge;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: double.infinity),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: chip.backgroundColor ?? theme.colorScheme.surfaceContainerHighest,
          shape: chip.shape ?? const StadiumBorder(),
        ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(tag, style: labelStyle),
              ),
            ),
            IconButton(
              tooltip: '删除标签 $tag',
              onPressed: onDeleted,
              icon: const Icon(Icons.close_rounded, size: 18),
              // 主题把 IconButton 的最小尺寸定为 48，这里收回到胶囊尺寸。
              style: IconButton.styleFrom(
                minimumSize: const Size(32, 32),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class CredentialFields extends StatelessWidget {
  const CredentialFields({
    super.key,
    required this.privateKey,
    required this.passphrase,
  });
  final TextEditingController privateKey, passphrase;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextFormField(
        controller: privateKey,
        minLines: 4,
        maxLines: 6,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          labelText: 'PEM / OpenSSH 私钥',
          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
        ),
        validator: (value) =>
            value != null &&
                value.contains('PRIVATE KEY-----') &&
                value.contains('-----END ')
            ? null
            : '请导入或生成私钥',
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: passphrase,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: '私钥口令（若已加密）'),
      ),
    ],
  );
}

typedef SaveUser = Future<void> Function(SshUser user, Credentials? stored);

class UserEditor extends StatefulWidget {
  const UserEditor({
    super.key,
    this.user,
    this.credentials,
    required this.onSave,
  });
  final SshUser? user;
  final Credentials? credentials;
  final SaveUser onSave;
  @override
  State<UserEditor> createState() => _UserEditorState();
}

class _UserEditorState extends State<UserEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user?.name);
  late final _key = TextEditingController(text: widget.credentials?.privateKey);
  late final _passphrase = TextEditingController(
    text: widget.credentials?.passphrase,
  );
  late final _publicKey = TextEditingController(
    text: widget.user?.publicKey.isNotEmpty == true
        ? widget.user!.publicKey
        : publicKeyFromPrivatePem(
                widget.credentials?.privateKey ?? '',
                widget.credentials?.passphrase,
              ) ??
              '',
  );
  late final String _id =
      widget.user?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
  bool _saving = false;
  String? _error, _copied;
  @override
  void dispose() {
    for (final controller in [_name, _key, _passphrase, _publicKey]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  String get _comment {
    final name = _name.text.trim();
    return name.isEmpty ? 'harbor' : name;
  }

  void _refreshPublicKey() {
    final pem = _key.text.trim();
    if (pem.isEmpty) {
      _publicKey.text = '';
      return;
    }
    _publicKey.text =
        publicKeyFromPrivatePem(
          pem,
          _passphrase.text.isEmpty ? null : _passphrase.text,
        ) ??
        _publicKey.text;
  }

  Future<void> _importKey() async {
    try {
      final text = await pickUtf8File();
      if (!mounted || text == null) return;
      setState(() {
        _key.text = text.trim();
        _error = null;
        _refreshPublicKey();
        if (_key.text.contains('PRIVATE KEY') &&
            _publicKey.text.isEmpty &&
            _passphrase.text.isEmpty) {
          _error = '私钥可能已加密，请填写口令后再试。';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取所选文件。');
    }
  }

  void _generateKey() {
    setState(() {
      _error = null;
      final pair = generateEd25519Key(
        comment: _comment,
        passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
      );
      _key.text = pair.privatePem;
      _publicKey.text = pair.publicOpenSsh;
    });
  }

  Future<void> _copyPublicKey() async {
    if (_publicKey.text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _publicKey.text.trim()));
    if (mounted) setState(() => _copied = '已复制公钥');
  }

  Future<void> _save() async {
    _refreshPublicKey();
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final user = SshUser(
      id: _id,
      name: _name.text.trim(),
      username: widget.user?.username ?? '',
      authMethod: AuthMethod.privateKey,
      publicKey: _publicKey.text.trim(),
    );
    final credentials = Credentials(
      privateKey: _key.text.trim(),
      passphrase: _passphrase.text,
    );
    try {
      await widget.onSave(user, credentials);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '保存失败，请检查系统安全存储及文件权限，然后重试。';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      insetPadding: EdgeInsets.all(
        MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 20 : 28,
          ),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const ExpressiveMark(
                      size: 44,
                      icon: Icons.vpn_key_rounded,
                      flower: true,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.user == null ? '新建凭证' : '编辑凭证',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      tooltip: '取消',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '生成 SSH 密钥对，或导入已有私钥。公钥可复制到服务器。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '显示名称',
                    hintText: '例如：生产部署',
                  ),
                  validator: _required,
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _importKey,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: const Text('导入私钥'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _saving ? null : _generateKey,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('生成密钥'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                CredentialFields(privateKey: _key, passphrase: _passphrase),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _publicKey,
                  minLines: 2,
                  maxLines: 4,
                  readOnly: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: '公钥（authorized_keys）',
                    suffixIcon: IconButton(
                      tooltip: '复制公钥',
                      onPressed: _copyPublicKey,
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ),
                ),
                if (_copied != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _copied!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('保存凭证'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
