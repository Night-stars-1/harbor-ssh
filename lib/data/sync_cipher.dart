import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

const _iterations = 210000;
const _aad = 'Harbor SSH sync v1';

Future<String> encryptSync(String plain, String password) =>
    compute(_encrypt, (plain, password));
Future<String> decryptSync(String encrypted, String password) =>
    compute(_decrypt, (encrypted, password));

Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: _iterations,
  bits: 256,
).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

Future<String> _encrypt((String, String) input) async {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(input.$1),
    secretKey: await _key(input.$2, salt),
    aad: utf8.encode(_aad),
  );
  return jsonEncode({
    'format': _aad,
    'iterations': _iterations,
    'salt': base64Encode(salt),
    'nonce': base64Encode(box.nonce),
    'mac': base64Encode(box.mac.bytes),
    'data': base64Encode(box.cipherText),
  });
}

Future<String> _decrypt((String, String) input) async {
  final envelope = jsonDecode(input.$1) as Map<String, dynamic>;
  if (envelope['format'] != _aad || envelope['iterations'] != _iterations) {
    throw const FormatException('不支持的加密格式');
  }
  final salt = base64Decode(envelope['salt'] as String);
  final nonce = base64Decode(envelope['nonce'] as String);
  final mac = base64Decode(envelope['mac'] as String);
  if (salt.length != 16 || nonce.length != 12 || mac.length != 16) {
    throw const FormatException('加密数据不完整');
  }
  final clear = await AesGcm.with256bits().decrypt(
    SecretBox(
      base64Decode(envelope['data'] as String),
      nonce: nonce,
      mac: Mac(mac),
    ),
    secretKey: await _key(input.$2, salt),
    aad: utf8.encode(_aad),
  );
  return utf8.decode(clear);
}
