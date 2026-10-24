import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:dartssh2/src/ssh_errors.dart';
import 'package:dartssh2/src/ssh_key_pair.dart';
import 'package:dartssh2/src/ssh_pem.dart';
import 'package:dartssh2/src/utils/bigint.dart';
import 'package:dartssh2/src/utils/list.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

const _rsaEncryptionOid = '1.2.840.113549.1.1.1';
const _ecPublicKeyOid = '1.2.840.10045.2.1';
const _ed25519Oid = '1.3.101.112';

/// Container for an unencrypted PKCS#8 private key
/// (`BEGIN PRIVATE KEY`, RFC 5208 PrivateKeyInfo / RFC 5958
/// OneAsymmetricKey).
///
/// Encrypted PKCS#8 (`BEGIN ENCRYPTED PRIVATE KEY`) is not handled here.
class Pkcs8KeyPair {
  /// Raw bytes of the ASN.1 DER-encoded PrivateKeyInfo blob.
  final Uint8List keyBlob;

  /// Creates a [Pkcs8KeyPair] container around [keyBlob].
  const Pkcs8KeyPair(this.keyBlob);

  /// Decodes a [Pkcs8KeyPair] from a parsed [SSHPem] structure.
  factory Pkcs8KeyPair.decode(SSHPem pem) {
    return Pkcs8KeyPair(pem.content);
  }

  /// PKCS#8 `PRIVATE KEY` must be unencrypted; encryption uses the separate
  /// `ENCRYPTED PRIVATE KEY` header.
  bool get isEncrypted => false;

  /// Parses the private key and returns the matching [SSHKeyPair].
  ///
  /// Supported algorithms: RSA (`rsaEncryption`), NIST P-256/P-384/P-521
  /// (`id-ecPublicKey`), and Ed25519.
  SSHKeyPair getPrivateKeys([String? passphrase]) {
    if (passphrase != null) {
      throw ArgumentError('Passphrase is not required for unencrypted keys');
    }

    try {
      return _decodePrivateKeyInfo(keyBlob);
    } on UnsupportedError {
      rethrow;
    } on SSHKeyDecodeError {
      rethrow;
    } on FormatException catch (e) {
      throw SSHKeyDecodeError(e.message);
    } catch (_) {
      // Never forward low-level parser details: they may embed offsets or
      // object content derived from private key material.
      throw SSHKeyDecodeError('Failed to decode PKCS#8 private key');
    }
  }

  static SSHKeyPair _decodePrivateKeyInfo(Uint8List keyBlob) {
    final root = _parseSingleObject(keyBlob, 'PKCS#8 PrivateKeyInfo');
    if (root is! ASN1Sequence) {
      throw FormatException('Invalid PKCS#8 PrivateKeyInfo');
    }

    final elements = root.elements;
    if (elements.length < 3) {
      throw FormatException('Invalid PKCS#8 PrivateKeyInfo');
    }

    final versionElement = elements[0];
    if (versionElement is! ASN1Integer) {
      throw FormatException('Invalid PKCS#8 version');
    }
    final version = versionElement.valueAsBigInteger;
    if (version != BigInt.zero && version != BigInt.one) {
      throw UnsupportedError('Unsupported PKCS#8 version: $version');
    }

    final (oid, parameters) = _decodeAlgorithmIdentifier(elements[1]);

    final privateKeyElement = elements[2];
    if (privateKeyElement is! ASN1OctetString) {
      throw FormatException('Invalid PKCS#8 private key');
    }
    final privateKey = privateKeyElement.octets;

    Uint8List? publicKey;
    var hasAttributes = false;
    for (var i = 3; i < elements.length; i++) {
      final element = elements[i];
      if (element.tag == 0xA0 && !hasAttributes) {
        // [0] attributes: not needed for SSH authentication.
        hasAttributes = true;
        continue;
      }
      if (element.tag == 0x81 || element.tag == 0xA1) {
        if (publicKey != null) {
          throw FormatException('Invalid PKCS#8 optional field');
        }
        // RFC 5958 encodes [1] publicKey as an IMPLICIT BIT STRING (0x81);
        // some encoders use an explicit BIT STRING (0xA1).
        publicKey = _decodeOptionalPublicKey(element);
        continue;
      }
      throw FormatException('Invalid PKCS#8 optional field');
    }
    if (publicKey != null && version != BigInt.one) {
      throw FormatException('PKCS#8 public key requires version 1');
    }

    switch (oid) {
      case _rsaEncryptionOid:
        _requireNullOrAbsentParameters(parameters);
        final key = _decodeRsaPrivateKey(privateKey);
        _verifyRsaPublicKey(key, publicKey);
        return key;

      case _ecPublicKeyOid:
        final curveOid = _namedCurveOid(parameters);
        final curveId = EcKeyPair.curveIdFromOid(curveOid);
        if (curveId == null) {
          throw UnsupportedError('Unsupported EC curve OID: $curveOid');
        }
        final key = _decodeEcPrivateKey(privateKey, curveId, curveOid);
        if (publicKey != null && !publicKey.equals(key.q)) {
          throw FormatException(
              'PKCS#8 EC public key does not match private key');
        }
        return key;

      case _ed25519Oid:
        _requireNullOrAbsentParameters(parameters);
        final key = _decodeEd25519PrivateKey(privateKey);
        if (publicKey != null && !publicKey.equals(key.publicKey)) {
          throw FormatException(
              'PKCS#8 Ed25519 public key does not match private key');
        }
        return key;

      default:
        throw UnsupportedError('Unsupported PKCS#8 algorithm: $oid');
    }
  }

  static (String, ASN1Object?) _decodeAlgorithmIdentifier(
      ASN1Object element) {
    if (element is! ASN1Sequence || element.elements.isEmpty) {
      throw FormatException('Invalid PKCS#8 algorithm identifier');
    }
    final elements = element.elements;
    if (elements.length > 2) {
      throw FormatException('Invalid PKCS#8 algorithm identifier');
    }
    final oidElement = elements[0];
    if (oidElement is! ASN1ObjectIdentifier) {
      throw FormatException('Invalid PKCS#8 algorithm identifier');
    }
    final oid = _decodeOid(oidElement);
    return (oid, elements.length == 2 ? elements[1] : null);
  }

  static Uint8List _decodeOptionalPublicKey(ASN1Object element) {
    if (element.tag == 0x81) {
      final value = element.valueBytes();
      if (value.isEmpty || value[0] != 0) {
        throw FormatException('Invalid PKCS#8 public key');
      }
      return Uint8List.sublistView(value, 1);
    }

    final inner = _parseSingleObject(
      element.valueBytes(),
      'PKCS#8 public key',
    );
    if (inner is! ASN1BitString || inner.unusedbits != 0) {
      throw FormatException('Invalid PKCS#8 public key');
    }
    return inner.contentBytes();
  }

  static BigInt _decodeScalar(Uint8List octets) {
    if (octets.isEmpty) {
      throw FormatException('Invalid EC private scalar');
    }
    return decodeBigIntWithSign(1, octets);
  }

  static OpenSSHEcdsaKeyPair _decodeEcPrivateKey(
    Uint8List keyBlob,
    String curveId,
    String curveOid,
  ) {
    final root = _parseSingleObject(keyBlob, 'PKCS#8 EC private key');
    if (root is! ASN1Sequence) {
      throw FormatException('Invalid PKCS#8 EC private key');
    }

    final elements = root.elements;
    if (elements.length < 2) {
      throw FormatException('Invalid PKCS#8 EC private key');
    }

    final versionElement = elements[0];
    if (versionElement is! ASN1Integer ||
        versionElement.valueAsBigInteger != BigInt.one) {
      throw FormatException('Invalid PKCS#8 EC private key version');
    }

    final scalarElement = elements[1];
    if (scalarElement is! ASN1OctetString) {
      throw FormatException('Invalid PKCS#8 EC private key');
    }
    final d = _decodeScalar(scalarElement.octets);

    final curve = EcKeyPair.curveForId(curveId);
    if (d <= BigInt.zero || d >= curve.n) {
      throw FormatException('EC private scalar out of range');
    }

    Uint8List? declaredPoint;
    var hasCurve = false;
    for (var i = 2; i < elements.length; i++) {
      final element = elements[i];
      if (element.tag == 0xA0 && !hasCurve) {
        hasCurve = true;
        final inner = _parseSingleObject(
          element.valueBytes(),
          'PKCS#8 EC private key parameters',
        );
        if (inner is! ASN1ObjectIdentifier ||
            _decodeOid(inner) != curveOid) {
          throw FormatException(
              'PKCS#8 EC private key curve does not match algorithm');
        }
        continue;
      }
      if (element.tag == 0xA1 && declaredPoint == null) {
        final inner = _parseSingleObject(
          element.valueBytes(),
          'PKCS#8 EC public point',
        );
        if (inner is! ASN1BitString || inner.unusedbits != 0) {
          throw FormatException('Invalid PKCS#8 EC public point');
        }
        declaredPoint = inner.contentBytes();
        continue;
      }
      throw FormatException('Invalid PKCS#8 EC private key');
    }

    final q = EcKeyPair.derivePublicPointForCurve(curve, d);
    if (declaredPoint != null && !declaredPoint.equals(q)) {
      throw FormatException(
          'PKCS#8 EC public point does not match private key');
    }

    return OpenSSHEcdsaKeyPair(curveId, q, d, '');
  }

  static OpenSSHEd25519KeyPair _decodeEd25519PrivateKey(Uint8List keyBlob) {
    final root = _parseSingleObject(keyBlob, 'PKCS#8 Ed25519 private key');
    if (root is! ASN1OctetString) {
      throw FormatException('Invalid PKCS#8 Ed25519 private key');
    }

    final seed = root.octets;
    if (seed.length != 32) {
      throw FormatException('Invalid Ed25519 private key length');
    }

    final signingKey = ed25519.SigningKey.fromSeed(seed);
    final publicKey = Uint8List.fromList(signingKey.verifyKey.asTypedList);
    final privateKey = Uint8List(64)
      ..setRange(0, 32, seed)
      ..setRange(32, 64, publicKey);
    return OpenSSHEd25519KeyPair(publicKey, privateKey, '');
  }

  static RsaPrivateKey _decodeRsaPrivateKey(Uint8List keyBlob) {
    final root = _parseSingleObject(keyBlob, 'PKCS#8 RSA private key');
    if (root is! ASN1Sequence || root.elements.length != 9) {
      throw FormatException('Invalid PKCS#8 RSA private key');
    }

    final values = <BigInt>[];
    for (final element in root.elements) {
      if (element is! ASN1Integer) {
        throw FormatException('Invalid PKCS#8 RSA private key');
      }
      values.add(element.valueAsBigInteger);
    }
    if (values[0] != BigInt.zero) {
      throw FormatException('Invalid PKCS#8 RSA private key version');
    }

    return RsaPrivateKey(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
      values[6],
      values[7],
      values[8],
    );
  }

  static void _verifyRsaPublicKey(RsaPrivateKey key, Uint8List? publicKey) {
    if (publicKey == null) {
      return;
    }

    final root = _parseSingleObject(publicKey, 'PKCS#8 RSA public key');
    if (root is! ASN1Sequence || root.elements.length != 2) {
      throw FormatException('Invalid PKCS#8 RSA public key');
    }

    final modulus = root.elements[0];
    final exponent = root.elements[1];
    if (modulus is! ASN1Integer || exponent is! ASN1Integer) {
      throw FormatException('Invalid PKCS#8 RSA public key');
    }
    if (modulus.valueAsBigInteger != key.n ||
        exponent.valueAsBigInteger != key.e) {
      throw FormatException(
          'PKCS#8 RSA public key does not match private key');
    }
  }

  static String _namedCurveOid(ASN1Object? parameters) {
    if (parameters is! ASN1ObjectIdentifier) {
      throw FormatException('EC algorithm requires a named curve');
    }
    return _decodeOid(parameters);
  }

  static void _requireNullOrAbsentParameters(ASN1Object? parameters) {
    if (parameters != null && parameters is! ASN1Null) {
      throw FormatException('Invalid algorithm parameters');
    }
  }

  static ASN1Object _parseSingleObject(Uint8List bytes, String label) {
    final end = _validateTlv(bytes, 0, bytes.length);
    if (end != bytes.length) {
      throw FormatException('Trailing data after $label');
    }

    final parser = ASN1Parser(bytes);
    final object = parser.nextObject();
    if (parser.hasNext()) {
      throw FormatException('Trailing data after $label');
    }
    return object;
  }

  /// Zero-copy DER structural pre-check.
  ///
  /// asn1lib builds parser views directly from the backing buffer, so a
  /// malformed length can read past the octet-string view into following
  /// fields. This walks TLV headers using only offsets and the [limit] of the
  /// field being parsed, recursing into constructed values, and throws before
  /// the real parser ever sees an out-of-bounds node.
  static int _validateTlv(Uint8List bytes, int offset, int limit) {
    if (offset >= limit) {
      throw FormatException('Invalid DER structure');
    }

    final firstTagByte = bytes[offset];
    var position = offset + 1;

    if ((firstTagByte & 0x1F) == 0x1F) {
      if (position >= limit || (bytes[position] & 0x7F) == 0) {
        throw FormatException('Invalid DER structure');
      }
      while (true) {
        if (position >= limit) {
          throw FormatException('Invalid DER structure');
        }
        if ((bytes[position++] & 0x80) == 0) {
          break;
        }
      }
    }

    if (position >= limit) {
      throw FormatException('Invalid DER structure');
    }

    final firstLengthByte = bytes[position++];
    final int length;
    if (firstLengthByte < 0x80) {
      length = firstLengthByte;
    } else {
      final lengthBytes = firstLengthByte & 0x7F;
      if (lengthBytes == 0 ||
          lengthBytes > 4 ||
          position + lengthBytes > limit) {
        throw FormatException('Invalid DER structure');
      }
      var value = 0;
      for (var i = 0; i < lengthBytes; i++) {
        value = (value << 8) | bytes[position++];
      }
      length = value;
    }

    final contentEnd = position + length;
    if (contentEnd > limit) {
      throw FormatException('Invalid DER structure');
    }

    if ((firstTagByte & 0x20) != 0) {
      var child = position;
      while (child < contentEnd) {
        child = _validateTlv(bytes, child, contentEnd);
      }
      if (child != contentEnd) {
        throw FormatException('Invalid DER structure');
      }
    }

    return contentEnd;
  }

  /// Decodes an OID from its DER content without trusting the parser's
  /// identifier string, which silently drops an unterminated final component.
  static String _decodeOid(ASN1ObjectIdentifier element) {
    final bytes = element.valueBytes();
    if (bytes.isEmpty) {
      throw FormatException('Invalid object identifier');
    }

    final components = <BigInt>[];
    var value = BigInt.zero;
    var inComponent = false;
    for (final byte in bytes) {
      if (!inComponent) {
        if (byte == 0x80) {
          throw FormatException('Invalid object identifier');
        }
        inComponent = true;
      }
      value = (value << 7) | BigInt.from(byte & 0x7F);
      if ((byte & 0x80) == 0) {
        components.add(value);
        value = BigInt.zero;
        inComponent = false;
      }
    }
    if (inComponent || components.isEmpty) {
      throw FormatException('Invalid object identifier');
    }

    final firstValue = components.first;
    final firstArc = firstValue < BigInt.from(40)
        ? 0
        : (firstValue < BigInt.from(80) ? 1 : 2);
    final secondArc = firstValue - BigInt.from(40 * firstArc);
    final builder = StringBuffer('$firstArc.${secondArc.toString()}');
    for (var i = 1; i < components.length; i++) {
      builder.write('.${components[i]}');
    }
    return builder.toString();
  }
}
