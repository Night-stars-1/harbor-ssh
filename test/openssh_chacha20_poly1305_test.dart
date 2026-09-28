// PointyCastle's Poly1305 implementation calls into code gated by
// `PlatformWeb.assertFullWidthInteger`, which throws `UnsupportedError`
// ("full width integer not supported on this platform") on every call when
// compiled to JavaScript. That's a pre-existing PointyCastle limitation
// unrelated to the 64-bit ByteData accessor fix this file's nonce test
// exercises (see utils/int.dart), so this suite stays VM-only; the AEAD
// coverage for the web CI job comes from AES-GCM instead (which PointyCastle
// does support on the web), in ssh_transport_aead_web_test.dart.
@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:math';

import 'package:dartssh2/src/utils/openssh_chacha20_poly1305.dart';
import 'package:pointycastle/export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenSSHChaCha20Poly1305', () {
    final key = Uint8List.fromList(List<int>.generate(64, (i) => i));
    // Fixed packet vector derived from OpenSSH 10.5's cipher-chachapoly.c:
    // K_2 is bytes 0..31, K_1 is bytes 32..63, and seqnr is 0x01020304.
    final plaintext = _bytes(
      '00000010'
      '04'
      '68656c6c6f20776f726c64'
      '00010203',
    );
    final ciphertext = _bytes(
      'bc79806b'
      '92aa79deb77e06debb1f4898a8415877'
      '75aca6b6c01a2037e45c6712ba973d9b',
    );
    const sequenceNumber = 0x01020304;

    test('matches the OpenSSH packet construction', () {
      final cipher = OpenSSHChaCha20Poly1305(key);

      expect(cipher.encryptPacket(plaintext, sequenceNumber), ciphertext);
      expect(cipher.decryptPacketLength(ciphertext, sequenceNumber), 16);
      expect(cipher.decryptPacket(ciphertext, sequenceNumber), plaintext);
    });

    test('copies key material on construction', () {
      final mutableKey = Uint8List.fromList(key);
      final cipher = OpenSSHChaCha20Poly1305(mutableKey);
      mutableKey.fillRange(0, mutableKey.length, 0xff);

      expect(cipher.encryptPacket(plaintext, sequenceNumber), ciphertext);
    });

    test('rejects changes to encrypted length, body, or tag', () {
      final cipher = OpenSSHChaCha20Poly1305(key);

      for (final index in [0, 4, ciphertext.length - 1]) {
        final tampered = Uint8List.fromList(ciphertext);
        tampered[index] ^= 1;

        expect(
          () => cipher.decryptPacket(tampered, sequenceNumber),
          throwsA(isA<InvalidCipherTextException>()),
        );
      }
    });

    test('uses the packet sequence number as part of the nonce', () {
      final cipher = OpenSSHChaCha20Poly1305(key);

      final first = cipher.encryptPacket(plaintext, 0);
      final second = cipher.encryptPacket(plaintext, 1);

      expect(second, isNot(first));
      expect(cipher.decryptPacket(first, 0), plaintext);
      expect(cipher.decryptPacket(second, 1), plaintext);
    });

    test(
      'matches the original engine across packet and sequence boundaries',
      () {
        final random = Random(20260928);
        for (final length in [
          0,
          1,
          7,
          8,
          15,
          16,
          31,
          32,
          63,
          64,
          65,
          32768,
          34996,
        ]) {
          for (final sequence in [
            0,
            1,
            255,
            256,
            65535,
            65536,
            0x7fffffff,
            0xffffffff,
          ]) {
            final key = Uint8List.fromList(
              List.generate(64, (_) => random.nextInt(256)),
            );
            final packet = Uint8List.fromList(
              List.generate(length + 4, (_) => random.nextInt(256)),
            );
            ByteData.sublistView(packet).setUint32(0, length);
            final cipher = OpenSSHChaCha20Poly1305(key);
            final reference = _referenceEncrypt(key, packet, sequence);
            expect(cipher.encryptPacket(packet, sequence), reference);
            expect(cipher.decryptPacketLength(reference, sequence), length);
            expect(cipher.decryptPacket(reference, sequence), packet);
            expect(
              () => cipher.decryptPacket(reference, sequence ^ 1),
              throwsA(isA<InvalidCipherTextException>()),
            );
          }
        }
      },
    );

    test('accepts unaligned views and rejects every changed packet byte', () {
      final storage = Uint8List(69)..setRange(3, 67, key);
      final cipher = OpenSSHChaCha20Poly1305(
        Uint8List.sublistView(storage, 3, 67),
      );
      final packetStorage = Uint8List(plaintext.length + 7)
        ..setRange(3, 3 + plaintext.length, plaintext);
      expect(
        cipher.encryptPacket(
          Uint8List.sublistView(packetStorage, 3, 3 + plaintext.length),
          sequenceNumber,
        ),
        ciphertext,
      );
      final encryptedStorage = Uint8List(ciphertext.length + 5)
        ..setRange(1, 1 + ciphertext.length, ciphertext);
      expect(
        cipher.decryptPacket(
          Uint8List.sublistView(encryptedStorage, 1, 1 + ciphertext.length),
          sequenceNumber,
        ),
        plaintext,
      );
      for (var i = 0; i < ciphertext.length; i++) {
        final changed = Uint8List.fromList(ciphertext)..[i] ^= 0x80;
        expect(
          () => cipher.decryptPacket(changed, sequenceNumber),
          throwsA(isA<InvalidCipherTextException>()),
        );
      }
    });

    test('validates key, packet, and sequence number lengths', () {
      expect(() => OpenSSHChaCha20Poly1305(Uint8List(63)), throwsArgumentError);

      final cipher = OpenSSHChaCha20Poly1305(key);
      expect(() => cipher.encryptPacket(Uint8List(3), 0), throwsArgumentError);
      expect(
        () => cipher.decryptPacketLength(Uint8List(3), 0),
        throwsArgumentError,
      );
      expect(() => cipher.decryptPacket(Uint8List(19), 0), throwsArgumentError);
      expect(() => cipher.encryptPacket(plaintext, -1), throwsRangeError);
      expect(
        () => cipher.encryptPacket(plaintext, 0x100000000),
        throwsRangeError,
      );
    });
  });
}

Uint8List _bytes(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);

// Independent oracle: the upstream PointyCastle construction, kept out of the
// production hot path. Compare authenticated wire bytes, not just round-trips.
Uint8List _referenceEncrypt(Uint8List key, Uint8List packet, int sequence) {
  final nonce = Uint8List(8);
  ByteData.sublistView(nonce).setUint32(4, sequence);
  final lengthCipher = ChaCha20Engine()
    ..init(
      true,
      ParametersWithIV(KeyParameter(Uint8List.sublistView(key, 32)), nonce),
    );
  final payloadCipher = ChaCha20Engine()
    ..init(
      true,
      ParametersWithIV(KeyParameter(Uint8List.sublistView(key, 0, 32)), nonce),
    );
  final block = Uint8List(64);
  payloadCipher.processBytes(block, 0, 64, block, 0);
  final output = Uint8List(packet.length + 16);
  lengthCipher.processBytes(packet, 0, 4, output, 0);
  payloadCipher.processBytes(packet, 4, packet.length - 4, output, 4);
  final mac = Poly1305()
    ..init(KeyParameter(Uint8List.sublistView(block, 0, 32)));
  mac.update(output, 0, packet.length);
  mac.doFinal(output, packet.length);
  return output;
}
