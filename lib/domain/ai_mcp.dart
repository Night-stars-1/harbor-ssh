/// Configuration for a remote MCP server reached over Streamable HTTP.
///
/// The object is immutable; settings layers build a new instance when a field
/// changes. Request headers travel with every call, so they are validated
/// before use and never rendered by [toString].
class AiMcpServer {
  const AiMcpServer({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
    this.enabled = true,
  });

  /// Headers owned by the transport. User-defined headers cannot replace them
  /// because a wrong session or content type would corrupt the session.
  static const reservedHeaders = {
    'accept',
    'connection',
    'content-length',
    'content-type',
    'host',
    'mcp-method',
    'mcp-name',
    'mcp-protocol-version',
    'mcp-session-id',
    'te',
    'transfer-encoding',
    'upgrade',
    'user-agent',
  };

  /// RFC 7230 `token` characters for a header field name.
  static final _headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  final String id;
  final String name;
  final String url;
  final Map<String, String> headers;
  final bool enabled;

  bool get isEnabled => enabled;

  AiMcpServer copyWith({
    String? id,
    String? name,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
  }) => AiMcpServer(
    id: id ?? this.id,
    name: name ?? this.name,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'headers': Map<String, String>.from(headers),
    'enabled': enabled,
  };

  /// Tolerates hand-edited or older JSON: missing fields become empty, invalid
  /// header entries are skipped, and an absent `enabled` means enabled.
  factory AiMcpServer.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) headers[key] = value;
      }
    }
    final id = json['id'];
    final name = json['name'];
    final url = json['url'];
    final enabled = json['enabled'];
    return AiMcpServer(
      id: id is String ? id : '',
      name: name is String ? name : '',
      url: url is String ? url : '',
      headers: headers,
      enabled: enabled is bool ? enabled : true,
    );
  }

  /// Rejects configurations that cannot be requested safely.
  ///
  /// Throws [FormatException] with a user-facing reason. URLs must be absolute
  /// HTTP(S) endpoints without embedded credentials; header names and values
  /// must be representable without header injection, and transport headers are
  /// reserved.
  void validate() {
    if (id.trim().isEmpty) {
      throw const FormatException('MCP 服务器缺少标识');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('MCP 服务器名称不能为空');
    }
    final rawUrl = url.trim();
    if (rawUrl.isEmpty) {
      throw const FormatException('MCP 服务器地址不能为空');
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('MCP 服务器地址必须是完整的 http:// 或 https:// 链接');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('MCP 服务器地址不能包含账号密码，请改用请求头');
    }
    if (uri.fragment.isNotEmpty) {
      throw const FormatException('MCP 服务器地址不能包含 # 片段');
    }
    final seen = <String>{};
    for (final entry in headers.entries) {
      final header = entry.key;
      if (!_headerName.hasMatch(header)) {
        throw FormatException('MCP 请求头「$header」名称无效');
      }
      final lower = header.toLowerCase();
      if (!seen.add(lower)) {
        throw FormatException('MCP 请求头「$header」重复');
      }
      if (reservedHeaders.contains(lower)) {
        throw FormatException('MCP 请求头「$header」由客户端管理，请移除');
      }
      for (final unit in entry.value.codeUnits) {
        if ((unit < 0x20 && unit != 0x09) || unit == 0x7f) {
          throw FormatException('MCP 请求头「$header」包含非法字符');
        }
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AiMcpServer &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.enabled == enabled &&
      _sameHeaders(other.headers);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    url,
    enabled,
    Object.hashAllUnordered(
      headers.entries.map(
        (entry) => Object.hash(entry.key.toLowerCase(), entry.value),
      ),
    ),
  );

  bool _sameHeaders(Map<String, String> other) {
    if (other.length != headers.length) return false;
    final normalized = <String, String>{
      for (final entry in other.entries) entry.key.toLowerCase(): entry.value,
    };
    for (final entry in headers.entries) {
      if (normalized[entry.key.toLowerCase()] != entry.value) return false;
    }
    return true;
  }

  /// Deliberately omits header values: they usually carry bearer tokens.
  @override
  String toString() => 'AiMcpServer($id, $url, enabled: $enabled)';
}
