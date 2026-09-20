import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_keys.dart';

void main() {
  test('生成的 Ed25519 私钥可解析，并导出匹配的公钥', () {
    final pair = generateEd25519Key(comment: 'deploy@host');
    expect(pair.privatePem, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(pair.publicOpenSsh, startsWith('ssh-ed25519 '));
    expect(pair.publicOpenSsh, contains('deploy@host'));
    final keys = SSHKeyPair.fromPem(pair.privatePem);
    expect(keys, isNotEmpty);
    expect(publicKeyFromPrivatePem(pair.privatePem), pair.publicOpenSsh);
  });

  test('加密生成的私钥需要口令才能读出公钥', () {
    final pair = generateEd25519Key(comment: 'ops', passphrase: 'secret');
    expect(SSHKeyPair.isEncryptedPem(pair.privatePem), isTrue);
    expect(publicKeyFromPrivatePem(pair.privatePem), isNull);
    expect(
      publicKeyFromPrivatePem(pair.privatePem, 'secret'),
      pair.publicOpenSsh,
    );
  });
}
