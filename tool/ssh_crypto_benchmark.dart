// Compile with `dart compile exe tool/ssh_crypto_benchmark.dart -o build/ssh_crypto_benchmark.exe`.
// Run the executable to measure authenticated SSH packet decryption in AOT.
// This measures CPU throughput, not end-to-end SFTP/network speed.
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/src/utils/openssh_chacha20_poly1305.dart';

void main() {
  final key = Uint8List.fromList(List.generate(64, (i) => i));
  final packet = Uint8List.fromList(List.generate(32772, (i) => i % 251));
  ByteData.sublistView(packet).setUint32(0, packet.length - 4);
  final cipher = OpenSSHChaCha20Poly1305(key);
  final encrypted = cipher.encryptPacket(packet, 1234);
  for (var repeat = 0; repeat < 3; repeat++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < 1024; i++) {
      final decoded = cipher.decryptPacket(encrypted, 1234);
      if (decoded.length != packet.length || decoded.last != packet.last) {
        throw StateError('Invalid decrypted packet');
      }
    }
    watch.stop();
    final rate =
        packet.length * 1024 / 1048576 / (watch.elapsedMicroseconds / 1e6);
    stdout.writeln(
      'Authenticated ChaCha20-Poly1305: ${rate.toStringAsFixed(2)} MiB/s',
    );
  }
}
