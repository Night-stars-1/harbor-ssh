import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart';

class HarborKeyPair {
  const HarborKeyPair({required this.privatePem, required this.publicOpenSsh});
  final String privatePem, publicOpenSsh;
}

HarborKeyPair generateEd25519Key({
  String comment = 'harbor',
  String? passphrase,
}) {
  final signing = SigningKey.generate();
  final pair = OpenSSHEd25519KeyPair(
    Uint8List.fromList(signing.verifyKey),
    Uint8List.fromList(signing),
    comment,
  );
  return HarborKeyPair(
    privatePem: pair.toPem(
      passphrase: passphrase == null || passphrase.isEmpty ? null : passphrase,
    ),
    publicOpenSsh: formatOpenSshPublicKey(pair, comment),
  );
}

String formatOpenSshPublicKey(SSHKeyPair pair, String comment) {
  final line = '${pair.name} ${base64.encode(pair.toPublicKey().encode())}';
  final label = comment.trim();
  return label.isEmpty ? line : '$line $label';
}

String? publicKeyFromPrivatePem(String pem, [String? passphrase]) {
  try {
    final keys = SSHKeyPair.fromPem(
      pem,
      passphrase == null || passphrase.isEmpty ? null : passphrase,
    );
    if (keys.isEmpty) return null;
    return formatOpenSshPublicKey(keys.first, keys.first.comment ?? '');
  } catch (_) {
    return null;
  }
}
