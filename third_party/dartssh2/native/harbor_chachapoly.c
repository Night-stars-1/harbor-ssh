/*
 * OpenSSH chacha20-poly1305@openssh.com packet cipher on libsodium's
 * ChaCha20 and Poly1305 primitives (PROTOCOL.chacha20poly1305):
 *
 *   key[0..31]  = K_2, the payload key; key[32..63] = K_1, the length key.
 *   nonce       = the packet sequence number as a big-endian uint64.
 *   length      = ChaCha20(K_1, nonce, counter 0) XOR packet_length.
 *   poly_key    = first 32 bytes of ChaCha20(K_2, nonce, counter 0).
 *   body        = ChaCha20(K_2, nonce, counter 1) XOR body.
 *   tag         = Poly1305(poly_key, encrypted length || encrypted body).
 *
 * Only the primitive implementations are linked; sodium_init() is not, so
 * implementation selection happens once in harbor_chachapoly_init().
 */
#include <stdint.h>
#include <string.h>

#include "crypto_onetimeauth_poly1305.h"
#include "crypto_verify_16.h"
#include "private/common.h"
#include "runtime.h"
#include "utils.h"

#include "crypto_onetimeauth/poly1305/donna/poly1305_donna.h"
#include "crypto_stream/chacha20/ref/chacha20_ref.h"
#if defined(HAVE_TI_MODE) && defined(HAVE_EMMINTRIN_H)
# include "crypto_onetimeauth/poly1305/sse2/poly1305_sse2.h"
#endif
#if defined(HAVE_AVX512FINTRIN_H) && defined(HAVE_AVX2INTRIN_H) && \
    defined(HAVE_EMMINTRIN_H) && defined(HAVE_TMMINTRIN_H) &&      \
    defined(HAVE_SMMINTRIN_H)
# include "crypto_stream/chacha20/dolbeau/chacha20_dolbeau-avx512.h"
#endif
#if defined(HAVE_AVX2INTRIN_H) && defined(HAVE_EMMINTRIN_H) && \
    defined(HAVE_TMMINTRIN_H) && defined(HAVE_SMMINTRIN_H)
# include "crypto_stream/chacha20/dolbeau/chacha20_dolbeau-avx2.h"
#endif
#if defined(HAVE_EMMINTRIN_H) && defined(HAVE_TMMINTRIN_H)
# include "crypto_stream/chacha20/dolbeau/chacha20_dolbeau-ssse3.h"
#endif

#if defined(_WIN32)
# define HARBOR_EXPORT __declspec(dllexport)
#else
# define HARBOR_EXPORT __attribute__((visibility("default")))
#endif

#define KEY_BYTES 64
#define LENGTH_BYTES 4
#define TAG_BYTES 16

static const crypto_stream_chacha20_implementation *chacha =
    &crypto_stream_chacha20_ref_implementation;
static const crypto_onetimeauth_poly1305_implementation *poly =
    &crypto_onetimeauth_poly1305_donna_implementation;

/* utils.c is not linked (it pulls in randombytes and guarded allocation);
 * the primitives only need it to wipe their stack state. */
void
sodium_memzero(void *const pnt, const size_t len)
{
    volatile unsigned char *volatile bytes = (volatile unsigned char *) pnt;
    size_t i;

    for (i = 0U; i < len; i++) {
        bytes[i] = 0U;
    }
}

/* Returns a bit mask naming the selected implementations, for diagnostics:
 * 1 = SSSE3, 2 = AVX2, 4 = AVX-512 ChaCha20; 8 = SSE2 Poly1305. */
HARBOR_EXPORT int
harbor_chachapoly_init(void)
{
    int selected = 0;

    _sodium_runtime_get_cpu_features();
#if defined(HAVE_AVX512FINTRIN_H) && defined(HAVE_AVX2INTRIN_H) && \
    defined(HAVE_EMMINTRIN_H) && defined(HAVE_TMMINTRIN_H) &&      \
    defined(HAVE_SMMINTRIN_H)
    if (selected == 0 && sodium_runtime_has_avx512f()) {
        chacha = &crypto_stream_chacha20_dolbeau_avx512_implementation;
        selected = 4;
    }
#endif
#if defined(HAVE_AVX2INTRIN_H) && defined(HAVE_EMMINTRIN_H) && \
    defined(HAVE_TMMINTRIN_H) && defined(HAVE_SMMINTRIN_H)
    if (selected == 0 && sodium_runtime_has_avx2()) {
        chacha = &crypto_stream_chacha20_dolbeau_avx2_implementation;
        selected = 2;
    }
#endif
#if defined(HAVE_EMMINTRIN_H) && defined(HAVE_TMMINTRIN_H)
    if (selected == 0 && sodium_runtime_has_ssse3()) {
        chacha = &crypto_stream_chacha20_dolbeau_ssse3_implementation;
        selected = 1;
    }
#endif
#if defined(HAVE_TI_MODE) && defined(HAVE_EMMINTRIN_H)
    if (sodium_runtime_has_sse2()) {
        poly = &crypto_onetimeauth_poly1305_sse2_implementation;
        selected |= 8;
    }
#endif
    return selected;
}

static void
sequence_nonce(unsigned char nonce[8], uint32_t sequence)
{
    nonce[0] = nonce[1] = nonce[2] = nonce[3] = 0;
    nonce[4] = (unsigned char) (sequence >> 24);
    nonce[5] = (unsigned char) (sequence >> 16);
    nonce[6] = (unsigned char) (sequence >> 8);
    nonce[7] = (unsigned char) sequence;
}

static void
poly_key(unsigned char out[32], const unsigned char nonce[8],
         const unsigned char *key)
{
    static const unsigned char zero[32];

    chacha->stream_xor_ic(out, zero, sizeof zero, nonce, 0U, key);
}

/* Decrypts only the four-byte packet length; it is not authenticated yet. */
HARBOR_EXPORT uint32_t
harbor_chachapoly_length(const unsigned char *key, uint32_t sequence,
                         const unsigned char *encrypted)
{
    unsigned char nonce[8];
    unsigned char plain[LENGTH_BYTES];

    sequence_nonce(nonce, sequence);
    chacha->stream_xor_ic(plain, encrypted, LENGTH_BYTES, nonce, 0U,
                          key + 32);
    return ((uint32_t) plain[0] << 24) | ((uint32_t) plain[1] << 16) |
           ((uint32_t) plain[2] << 8) | (uint32_t) plain[3];
}

/* [in] holds length || body || tag ([length] excludes the tag). [out]
 * receives length || body. Returns 0 on success, -1 when the tag does not
 * authenticate; in that case nothing has been written to [out]. */
HARBOR_EXPORT int
harbor_chachapoly_open(const unsigned char *key, uint32_t sequence,
                       const unsigned char *in, uint32_t length,
                       unsigned char *out)
{
    unsigned char nonce[8];
    unsigned char mac_key[32];
    int           result;

    sequence_nonce(nonce, sequence);
    poly_key(mac_key, nonce, key);
    result = poly->onetimeauth_verify(in + length, in, length, mac_key);
    sodium_memzero(mac_key, sizeof mac_key);
    if (result != 0) {
        return -1;
    }
    chacha->stream_xor_ic(out, in, LENGTH_BYTES, nonce, 0U, key + 32);
    chacha->stream_xor_ic(out + LENGTH_BYTES, in + LENGTH_BYTES,
                          length - LENGTH_BYTES, nonce, 1U, key);
    return 0;
}

/* [in] holds length || body; [out] receives the encrypted packet followed by
 * the 16-byte tag. */
HARBOR_EXPORT void
harbor_chachapoly_seal(const unsigned char *key, uint32_t sequence,
                       const unsigned char *in, uint32_t length,
                       unsigned char *out)
{
    unsigned char nonce[8];
    unsigned char mac_key[32];

    sequence_nonce(nonce, sequence);
    chacha->stream_xor_ic(out, in, LENGTH_BYTES, nonce, 0U, key + 32);
    chacha->stream_xor_ic(out + LENGTH_BYTES, in + LENGTH_BYTES,
                          length - LENGTH_BYTES, nonce, 1U, key);
    poly_key(mac_key, nonce, key);
    poly->onetimeauth(out + length, out, length, mac_key);
    sodium_memzero(mac_key, sizeof mac_key);
}
