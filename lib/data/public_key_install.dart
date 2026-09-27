import 'dart:convert';
import 'dart:typed_data';

/// Longest accepted OpenSSH public key line.
///
/// A 16384-bit RSA key still fits well below this, so the cap only rejects
/// garbage that was pasted into the preferences JSON.
const int maxOpenSshPublicKeyLength = 8192;

/// A validated single-line OpenSSH public key.
class OpenSshPublicKey {
  const OpenSshPublicKey({
    required this.line,
    required this.type,
    required this.blob,
  });

  /// The key in canonical form: `type body [comment]`, without a trailing
  /// newline and with a single space between the fields.
  final String line;

  /// The key algorithm, for example `ssh-ed25519`.
  final String type;

  /// The base64 key body. It is unique per key, so it is what an existing
  /// `authorized_keys` entry is matched against, whatever its comment says.
  final String blob;
}

/// Failure while installing a public key on the server.
class PublicKeyInstallFailure implements Exception {
  const PublicKeyInstallFailure(this.message, {this.unknown = false});

  /// User-facing reason.
  final String message;

  /// Whether the remote file may have changed.
  ///
  /// True when the outcome could not be confirmed: a timeout, a dropped
  /// channel, a failed read-back, or a create whose answer never arrived. The
  /// caller must not claim the key was not installed, and may safely run the
  /// same install again. False means no key byte was written and
  /// `authorized_keys` holds no new entry, although the permissions of
  /// `~/.ssh` or `authorized_keys` may have been adjusted by the same call.
  ///
  /// Permissions the server will not report or accept (a missing mode, or a
  /// mode other than 0700/0600 after `setStat`) are refused as a definite
  /// failure rather than being reported as an install.
  final bool unknown;

  @override
  String toString() => 'PublicKeyInstallFailure: $message';
}

final RegExp _printableLine = RegExp(r'^[^\x00-\x1f\x7f\x85\u2028\u2029]+$');

/// Algorithm names only: options such as `no-pty` or `from="..."` carry
/// characters (`=`, `"`, `,`) that a key algorithm never contains, and their
/// body field would not decode as the key they claim to be.
final RegExp _keyType = RegExp(r'^[a-z0-9][a-z0-9@._+-]*$');

final RegExp _base64Body = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Validates a single OpenSSH public key line and returns it in canonical form.
///
/// Throws a [FormatException] for anything that is not exactly one key: empty
/// input, several lines, control characters, a line that is far too long, an
/// option prefix instead of a key algorithm, or a base64 body that does not
/// decode to that algorithm's key. The check is pure, so callers can reject
/// bad input before opening any connection.
String validatedOpenSshPublicKey(String raw) => parseOpenSshPublicKey(raw).line;

/// Parses [raw] into its algorithm and key body. See
/// [validatedOpenSshPublicKey] for the validation rules.
OpenSshPublicKey parseOpenSshPublicKey(String raw) {
  final line = raw.trim();
  if (line.isEmpty) {
    throw const FormatException('公钥为空');
  }
  if (line.length > maxOpenSshPublicKeyLength) {
    throw const FormatException('公钥过长');
  }
  if (line.contains('\n') || line.contains('\r') || line.contains('\x00')) {
    throw const FormatException('公钥必须是单行文本');
  }
  if (!_printableLine.hasMatch(line)) {
    throw const FormatException('公钥包含控制字符');
  }
  final fields = line.split(' ').where((field) => field.isNotEmpty).toList();
  if (fields.length < 2) {
    throw const FormatException('公钥缺少类型或密钥内容');
  }
  final type = fields[0];
  final blob = fields[1];
  if (!_keyType.hasMatch(type)) {
    throw const FormatException('公钥类型不合法，也不接受选项前缀');
  }
  final body = _decodeBase64(blob);
  if (body == null) {
    throw const FormatException('公钥内容不是合法的 base64 编码');
  }
  _checkKeyBody(type, body);
  return OpenSshPublicKey(
    line: fields.length > 2
        ? '$type $blob ${fields.sublist(2).join(' ')}'
        : '$type $blob',
    type: type,
    blob: blob,
  );
}

/// The key fields one `authorized_keys` line holds: the algorithm and the
/// base64 body of its key. Options in front of the key and the free-form
/// comment after it are not part of them.
typedef OpenSshKeyFields = ({String type, String blob});

/// Finds the first valid key of an `authorized_keys` [line].
///
/// Returns null for an empty line, a `#` comment, or a line whose fields never
/// form a valid key. Only that one key counts: text after it is a comment, so
/// it can hold anything that merely looks like a key without turning the line
/// into an entry for that key.
/// Spaces inside quoted options (including escaped quotes) are not field
/// separators: commands may contain text that looks like another public key.
OpenSshKeyFields? findOpenSshKeyFields(String line) {
  final text = line.trim();
  if (text.isEmpty || text.startsWith('#')) return null;
  String? type;
  var offset = 0;
  while (offset < text.length) {
    while (offset < text.length &&
        (text.codeUnitAt(offset) == 0x20 || text.codeUnitAt(offset) == 0x09)) {
      offset++;
    }
    if (offset == text.length) break;
    final start = offset;
    var quoted = false;
    var escaped = false;
    while (offset < text.length) {
      final code = text.codeUnitAt(offset);
      if (escaped) {
        escaped = false;
      } else if (quoted && code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        quoted = !quoted;
      } else if (!quoted && (code == 0x20 || code == 0x09)) {
        break;
      }
      offset++;
    }
    if (quoted || escaped) return null;
    final field = text.substring(start, offset);
    if (type != null && _decodeKeyBody(field, type) != null) {
      return (type: type, blob: field);
    }
    type = _keyType.hasMatch(field) ? field : null;
  }
  return null;
}

/// Decodes [blob] as strict base64, or null when it is malformed.
Uint8List? _decodeBase64(String blob) {
  if (blob.length % 4 != 0 || !_base64Body.hasMatch(blob)) return null;
  try {
    return base64.decode(blob);
  } on FormatException {
    return null;
  }
}

/// Decodes [blob] when it is a well-formed body for [type], else null.
Uint8List? _decodeKeyBody(String blob, String type) {
  final body = _decodeBase64(blob);
  if (body == null) return null;
  try {
    _checkKeyBody(type, body);
  } on FormatException {
    return null;
  }
  return body;
}

/// Rejects a base64 body that is not a well-formed key blob.
///
/// RFC 4253 encodes a key as a sequence of length-prefixed fields, starting
/// with the algorithm name. Requiring that name to equal the one written in
/// the line is what makes an option prefix impossible to slip through: no
/// prefix can produce a body whose first field repeats itself.
void _checkKeyBody(String type, Uint8List body) {
  if (body.length < 12) {
    throw const FormatException('公钥内容不完整');
  }
  final nameLength = _readUint32(body, 0);
  if (nameLength == 0 || 4 + nameLength > body.length) {
    throw const FormatException('公钥内容不完整');
  }
  final String name;
  try {
    name = utf8.decode(Uint8List.sublistView(body, 4, 4 + nameLength));
  } on FormatException {
    throw const FormatException('公钥内容不完整');
  }
  if (name != type) {
    throw const FormatException('公钥类型与密钥内容不一致');
  }
  var offset = 4 + nameLength;
  var fields = 0;
  while (offset < body.length) {
    if (offset + 4 > body.length) {
      throw const FormatException('公钥内容不完整');
    }
    final length = _readUint32(body, offset);
    offset += 4;
    if (length == 0 || offset + length > body.length) {
      throw const FormatException('公钥内容不完整');
    }
    offset += length;
    fields++;
  }
  if (fields == 0) {
    throw const FormatException('公钥内容缺少密钥数据');
  }
}

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
