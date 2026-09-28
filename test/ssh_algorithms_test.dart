import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_algorithms.dart';

void main() {
  test('优先使用带认证的 ChaCha20，保留服务器兼容回退算法', () {
    const defaults = SSHAlgorithms();
    expect(harborSshAlgorithms.cipher.first, SSHCipherType.chacha20poly1305);
    expect(harborSshAlgorithms.cipher.first.isAead, isTrue);
    expect(harborSshAlgorithms.cipher.toSet(), defaults.cipher.toSet());
    expect(harborSshAlgorithms.kex, defaults.kex);
    expect(harborSshAlgorithms.hostkey, defaults.hostkey);
    expect(harborSshAlgorithms.mac, defaults.mac);
  });
}
