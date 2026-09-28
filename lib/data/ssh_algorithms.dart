import 'package:dartssh2/dartssh2.dart';

/// Prefer authenticated ChaCha20-Poly1305 for the pure-Dart SSH implementation.
/// Its software implementation avoids the AES-GCM CPU bottleneck seen during
/// bulk transfers. Retain the library's other modern ciphers as fallbacks for
/// servers that do not offer ChaCha20; key exchange, host-key verification and
/// MAC policy keep the library defaults.
const harborSshAlgorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes256gcm,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128ctr,
  ],
);
