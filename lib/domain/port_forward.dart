enum PortForwardType {
  local('本地转发'),
  remote('远程转发'),
  dynamic('SOCKS5 代理');

  const PortForwardType(this.label);
  final String label;
}

class PortForwardRule {
  const PortForwardRule({
    required this.id,
    required this.name,
    required this.type,
    this.bindHost = '127.0.0.1',
    required this.bindPort,
    this.targetHost = '127.0.0.1',
    this.targetPort = 0,
  });
  final String id, name, bindHost, targetHost;
  final PortForwardType type;
  final int bindPort, targetPort;

  String get description => switch (type) {
    PortForwardType.local => '本机监听，经 SSH 连接服务器侧目标',
    PortForwardType.remote => '服务器监听，经 SSH 连接本机侧目标',
    PortForwardType.dynamic => '本机 SOCKS5 代理，经 SSH 访问目标（仅 TCP）',
  };

  static String endpoint(String host, int port) =>
      host.contains(':') ? '[$host]:$port' : '$host:$port';

  String route({int? actualPort}) {
    final source = endpoint(bindHost, actualPort ?? bindPort);
    return type == PortForwardType.dynamic
        ? '$source → SOCKS5'
        : '$source → ${endpoint(targetHost, targetPort)}';
  }

  void validate() {
    if (id.isEmpty || name.trim().isEmpty) {
      throw const FormatException('请填写规则名称');
    }
    if (!_validHost(bindHost)) throw const FormatException('请填写有效的监听地址');
    if (bindPort < 0 || bindPort > 65535) {
      throw const FormatException('监听端口须为 0–65535，0 表示自动分配');
    }
    if (type == PortForwardType.dynamic) {
      if (!['127.0.0.1', '::1', 'localhost'].contains(bindHost)) {
        throw const FormatException('SOCKS5 无认证，仅支持监听本机回环地址');
      }
    } else {
      if (!_validHost(targetHost)) throw const FormatException('请填写有效的目标地址');
      if (targetPort < 1 || targetPort > 65535) {
        throw const FormatException('目标端口须为 1–65535');
      }
    }
  }

  static bool _validHost(String value) =>
      value.isNotEmpty && !RegExp(r'\s|/|\[|\]').hasMatch(value);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'bindHost': bindHost,
    'bindPort': bindPort,
    'targetHost': targetHost,
    'targetPort': targetPort,
  };
  factory PortForwardRule.fromJson(Map<String, dynamic> json) {
    final rule = PortForwardRule(
      id: json['id'] as String,
      name: json['name'] as String,
      type: PortForwardType.values.byName(json['type'] as String),
      bindHost: json['bindHost'] as String,
      bindPort: json['bindPort'] as int,
      targetHost: json['targetHost'] as String? ?? '127.0.0.1',
      targetPort: json['targetPort'] as int? ?? 0,
    );
    rule.validate();
    return rule;
  }
}

enum PortForwardStatus { stopped, starting, running, stopping, failed }

class PortForwardState {
  const PortForwardState({
    this.status = PortForwardStatus.stopped,
    this.port,
    this.error,
  });
  final PortForwardStatus status;
  final int? port;
  final String? error;
  bool get busy =>
      status == PortForwardStatus.starting ||
      status == PortForwardStatus.stopping;
  bool get active => busy || status == PortForwardStatus.running;
  String get label => switch (status) {
    PortForwardStatus.stopped => '已停止',
    PortForwardStatus.starting => '正在启动',
    PortForwardStatus.running => '运行中',
    PortForwardStatus.stopping => '正在停止',
    PortForwardStatus.failed => '启动失败',
  };
}
