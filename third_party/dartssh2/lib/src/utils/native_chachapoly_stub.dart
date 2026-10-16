import 'dart:typed_data';

/// Web stand-in for `native_chachapoly.dart`. There is no FFI on the web, so
/// [nativeChaChaPolyImplementations] is null and the Dart implementation is
/// always selected; the functions below are never reached.
const int? nativeChaChaPolyImplementations = null;

int nativeChaChaPolyLength(
  Uint8List key,
  int sequenceNumber,
  Uint8List encryptedLength,
) =>
    throw UnsupportedError('Native ChaCha20-Poly1305 is unavailable');

bool nativeChaChaPolyOpen(
  Uint8List key,
  int sequenceNumber,
  Uint8List packet,
  int length,
  Uint8List output,
) =>
    throw UnsupportedError('Native ChaCha20-Poly1305 is unavailable');

void nativeChaChaPolySeal(
  Uint8List key,
  int sequenceNumber,
  Uint8List packet,
  Uint8List output,
) =>
    throw UnsupportedError('Native ChaCha20-Poly1305 is unavailable');
