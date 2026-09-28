# SFTP download performance — 2026-09-28

Two bottlenecks were measured on Windows x64 Release/AOT:

1. PointyCastle's ChaCha20 stream implementation limited authenticated SSH
   packet decryption to approximately 26 MiB/s on the test machine. Replacing
   only the stream primitive with `cryptography`'s synchronous implementation
   raised the CPU-only benchmark to approximately 66 MiB/s. OpenSSH's separate
   length key and Poly1305 construction are unchanged.
2. Receive-window grants were delayed until half the 2 MiB channel window was
   consumed. Replenishing at the earlier of half the window or three maximum
   packets reduced stalls on a measured 33–44 ms connection. The initial
   window size, packet limits and paused-consumer backpressure are unchanged.

The source changes are pinned in `third_party/dartssh2` and described in its
`HARBOR_PATCHES.md`; the shared dependency cache is not modified.

## Read-only server comparison

Using the user-selected ROM server and the same 128 MiB prefix of its
3,142,561,010-byte OTA ZIP, the benchmark used the saved credential in memory
and required an exact match to the saved host fingerprint. No remote file was
modified. Local temporary files were flushed, hashed, and removed.

| Path | Consecutive results (MiB/s) |
| --- | --- |
| Original transport, buffered local disk | 14.83, 14.76, 14.84 |
| Patched transport, buffered local disk, first run | 23.79, 23.94, 22.33 |
| Patched transport, buffered local disk, repeat | 22.31, 25.14, 24.19 |
| Paramiko with native AES-GCM, 2 MiB window, memory sink | 22.75, 24.94 |
| Paramiko with native AES-GCM, 16 MiB window, memory sink | 26.81, 27.62 |

Every 128 MiB prefix had the same SHA-256 digest across both implementations
and all repetitions. Native AES-GCM is a comparison implementation, not a new
production dependency. TCP_NODELAY alone did not produce a consistent gain
and is not changed in production.

These are standalone AOT transport measurements, including local buffered
writes for Harbor; they are not a full-file or graphical-UI benchmark. Network
conditions, concurrent work, storage and server cipher support affect results.
In particular, servers which cannot negotiate ChaCha retain the existing AES
fallback implementations; the CPU improvement above does not apply to AES.

## Regression checks and reproducible CPU benchmark

```text
flutter test test/openssh_chacha20_poly1305_test.dart test/ssh_channel_window_test.dart
flutter test test/download_stream_test.dart test/ssh_algorithms_test.dart
dart compile exe tool/ssh_crypto_benchmark.dart -o build/ssh_crypto_benchmark.exe
build/ssh_crypto_benchmark.exe
```

The crypto tests cover the upstream fixed packet vector, exact ciphertext
agreement with the original engine, boundary sequence numbers, unaligned
input views, tampered bytes, wrong sequence numbers and key/length validation.
The window tests cover grant timing, bounded grant frequency, pause/resume,
late subscription, small-window liveness and rejection of invalid packets.
