/// Native `chacha20-poly1305@openssh.com` packet routines, built by
/// `hook/build.dart` from `native/harbor_chachapoly.c` and a pinned libsodium
/// subset. All calls are leaf calls on the caller's buffers: no copies.
@DefaultAsset('package:dartssh2/harbor_chachapoly')
library;

import 'dart:ffi';
import 'dart:typed_data';

/// Bit mask of the SIMD implementations libsodium selected for this CPU, or
/// null when this build does not bundle the native library.
final int? nativeChaChaPolyImplementations = _load();

int? _load() {
  try {
    return _init();
  } on ArgumentError {
    // The asset is missing: the caller falls back to the Dart implementation.
    return null;
  }
}

int nativeChaChaPolyLength(
  Uint8List key,
  int sequenceNumber,
  Uint8List encryptedLength,
) =>
    _length(key.address, sequenceNumber, encryptedLength.address);

/// Authenticates `packet[0..length)` against the tag that follows it and, only
/// if it is valid, writes the plaintext into [output].
bool nativeChaChaPolyOpen(
  Uint8List key,
  int sequenceNumber,
  Uint8List packet,
  int length,
  Uint8List output,
) =>
    _open(key.address, sequenceNumber, packet.address, length,
        output.address) ==
    0;

/// Writes the encrypted [packet] followed by its tag into [output].
void nativeChaChaPolySeal(
  Uint8List key,
  int sequenceNumber,
  Uint8List packet,
  Uint8List output,
) =>
    _seal(key.address, sequenceNumber, packet.address, packet.length,
        output.address);

@Native<Int32 Function()>(symbol: 'harbor_chachapoly_init')
external int _init();

@Native<Uint32 Function(Pointer<Uint8>, Uint32, Pointer<Uint8>)>(
  symbol: 'harbor_chachapoly_length',
  isLeaf: true,
)
external int _length(Pointer<Uint8> key, int sequence, Pointer<Uint8> input);

@Native<
    Int32 Function(
        Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint8>)>(
  symbol: 'harbor_chachapoly_open',
  isLeaf: true,
)
external int _open(
  Pointer<Uint8> key,
  int sequence,
  Pointer<Uint8> input,
  int length,
  Pointer<Uint8> output,
);

@Native<
    Void Function(
        Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint8>)>(
  symbol: 'harbor_chachapoly_seal',
  isLeaf: true,
)
external void _seal(
  Pointer<Uint8> key,
  int sequence,
  Pointer<Uint8> input,
  int length,
  Pointer<Uint8> output,
);
