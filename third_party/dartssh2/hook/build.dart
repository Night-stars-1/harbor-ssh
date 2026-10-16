import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds `native/harbor_chachapoly.c` and the pinned libsodium subset it
/// uses into one shared library. See HARBOR_PATCHES.md.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final architecture = code.targetArchitecture;
    final x86 =
        architecture == Architecture.x64 || architecture == Architecture.ia32;
    final bits64 =
        architecture == Architecture.x64 || architecture == Architecture.arm64;
    final msvc = code.targetOS == OS.windows;
    const sodium = 'native/libsodium/src/libsodium';
    await CBuilder.library(
      name: 'harbor_chachapoly',
      assetName: 'harbor_chachapoly',
      sources: [
        'native/harbor_chachapoly.c',
        '$sodium/crypto_stream/chacha20/ref/chacha20_ref.c',
        '$sodium/crypto_onetimeauth/poly1305/donna/poly1305_donna.c',
        '$sodium/crypto_verify/verify.c',
        '$sodium/sodium/runtime.c',
        if (x86) ...[
          '$sodium/crypto_stream/chacha20/dolbeau/chacha20_dolbeau-ssse3.c',
          '$sodium/crypto_stream/chacha20/dolbeau/chacha20_dolbeau-avx2.c',
          '$sodium/crypto_stream/chacha20/dolbeau/chacha20_dolbeau-avx512.c',
          '$sodium/crypto_onetimeauth/poly1305/sse2/poly1305_sse2.c',
        ],
      ],
      includes: ['$sodium/include/sodium', sodium],
      // MSVC derives the intrinsic-header macros in private/common.h itself;
      // other compilers get what libsodium's own build.zig defines.
      defines: {
        'SODIUM_STATIC': null,
        'NATIVE_LITTLE_ENDIAN': null,
        if (!msvc) ...{
          'CONFIGURED': '1',
          'HAVE_INLINE_ASM': null,
          if (bits64) 'HAVE_TI_MODE': null,
          if (x86) ...{
            'HAVE_CPUID': null,
            'HAVE_XGETBV_ASM': null,
            'HAVE_MMINTRIN_H': null,
            'HAVE_EMMINTRIN_H': null,
            'HAVE_PMMINTRIN_H': null,
            'HAVE_TMMINTRIN_H': null,
            'HAVE_SMMINTRIN_H': null,
            'HAVE_AVXINTRIN_H': null,
            'HAVE_AVX2INTRIN_H': null,
            'HAVE_AVX512FINTRIN_H': null,
          },
        },
      },
      flags: msvc
          ? const []
          : const [
              '-fvisibility=hidden',
              '-fno-strict-aliasing',
              '-fwrapv',
            ],
    ).run(input: input, output: output);
  });
}
