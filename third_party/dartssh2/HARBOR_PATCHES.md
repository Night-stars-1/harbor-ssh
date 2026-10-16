# Harbor SSH patches to dartssh2 4.1.0

This directory contains the library sources, license and package metadata from
the resolved dartssh2 4.1.0 release. It is pinned here so the application's
performance fix is reproducible without modifying the shared pub cache.

## ChaCha20 stream throughput (2026-09-28)

`lib/src/utils/openssh_chacha20_poly1305.dart` uses the synchronous ChaCha20
stream primitive from `cryptography` 2.9.0 instead of PointyCastle's stream
engine. The OpenSSH packet construction is unchanged: two separate keys,
encrypted packet length, packet sequence nonce, counter-zero Poly1305 key,
counter-one payload and Poly1305 over encrypted length plus encrypted body.
The existing constant-time tag comparison runs before any plaintext is returned.
This does not use RFC 8439 AEAD and does not remove authentication.

The original 64-bit nonce is prefixed with four zero bytes for the stream
primitive's IETF nonce layout. With the counter below 2^32 the ChaCha states
are identical; the transport caps each SSH packet at 35,000 bytes.

Host trust, key exchange, rekeying, cipher negotiation and SFTP behavior
remain upstream. Other negotiated ciphers retain their existing implementations.

Regression tests live in the application test suite:
`test/openssh_chacha20_poly1305_test.dart` includes the upstream fixed packet
vector, tampering rejection, nonce and key validation plus differential tests
against the original PointyCastle construction.

## Native ChaCha20-Poly1305 (2026-10-16)

`hook/build.dart` compiles `native/harbor_chachapoly.c` together with a
subset of libsodium 1.0.22-stable (ChaCha20 reference/SSSE3/AVX2/AVX-512,
Poly1305 donna/SSE2, `crypto_verify_16`, CPU detection) into the
`package:dartssh2/harbor_chachapoly` code asset. The release tarball was
verified with libsodium's published minisign key before vendoring; its
SHA-256 was
`8622a647cac0ef7343e1e476a70c9298f49e37f5deca21c4bbf7565dd1916017`.
Only the files under `native/libsodium` are used; they are unmodified.

`harbor_chachapoly.c` performs the same OpenSSH construction as the Dart
code above (separate length key, counter-zero Poly1305 key, counter-one
body). The tag is verified with libsodium's constant-time comparison before
any plaintext is written. `utils.c` is not linked; the file supplies the
`sodium_memzero` the primitives use to wipe stack state.

`OpenSSHChaCha20Poly1305` uses the native routines when the asset is
present and keeps the Dart implementation as the fallback (web, or a build
without the asset). `test/openssh_chacha20_poly1305_test.dart` runs every
existing vector, boundary and tampering case against both implementations
and checks that the VM test build bundles the native library.

## Timely receive-window replenishment (2026-09-28)

`lib/src/ssh_channel.dart` now replenishes the receive window at the earlier
of half the window or three maximum-size packets. The upstream half-window
rule waited for 1 MiB at default settings, causing additional stalls on the
measured 33–40 ms link. The additional early-refill rule follows the same
approach as OpenSSH, while still batching rather than replying to each packet.
The initial 2 MiB window, packet limits, paused-consumer backpressure and
small-window deadlock protections are unchanged.

`test/ssh_channel_window_test.dart` preserves upstream protocol checks and
tests early replenishment, bounded grant frequency, pause/resume, late
subscription, small windows and invalid remote packets.

## Port-forward lifecycle (2026-09-29)

`lib/src/ssh_client.dart` retains the remote-forward registration until the
server acknowledges cancellation. A rejected cancellation can therefore be
retried without losing the active listener's incoming channels. Successful
cancellation also closes its incoming connection stream.

`lib/src/forward/dynamic_forward_io.dart` destroys a channel returned after a
SOCKS dial timeout, caps accepted connections before negotiation, and pipes
both directions with backpressure. TCP EOF closes only the opposite write
side; buffered responses are flushed before full cleanup. Finished clients
are removed from the connection set so repeated use does not exhaust it.

The SOCKS parser accepts a socket event containing both headers and a large
application payload. Protocol length fields bound incomplete headers, and
reading pauses during dial; coalesced payload is no longer incorrectly
rejected by a 32 KiB handshake-buffer limit. The loopback test writes the
SOCKS greeting, CONNECT request and 3 MiB payload together to cover this.

`test/port_forward_integration_test.dart` covers local, remote and SOCKS
forwarding through a temporary loopback Paramiko server, including a 3 MiB
response after client EOF, port reuse, cancellation rejection/retry and SSH
disconnect. `test/socks_forward_lifecycle_test.dart` covers late dial completion
and the connection cap. No real host credentials are used.
