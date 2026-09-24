/*---------------------------------------------------------------------------
  Licence key verification. Offline, no account, no server -- the key carries
  everything, and this file checks it against a public key compiled into the
  exe.

  A key is base32 (RFC 4648, padding stripped, dashes for legibility) of:

      [0]     format byte, 1
      [1..3]  purchase date, days since 2020-01-01, big-endian
      [4..n]  licensee name, UTF-8
      [n..]   ECDSA P-256 signature over bytes [0..n], raw r||s, 64 bytes

  Only the public key is here, so a keygen cannot be built from the binary --
  minting needs license-private.pem, which lives off the build machine. See
  mintkey.sh.

  Naming: Koka mangles module `license` + `f` to `kk_license_f`, so the C here
  is `kk_lic_*` and cannot collide.
---------------------------------------------------------------------------*/
#include <windows.h>
#include <bcrypt.h>
#include <string.h>

#define LIC_SIG_LEN  64
#define LIC_HEAD_LEN 4
#define LIC_NAME_MAX 48
#define LIC_MAX      (LIC_HEAD_LEN + LIC_NAME_MAX + LIC_SIG_LEN)

/* The public half of the signing key. Swapping this invalidates every key
   ever issued, so it changes only if the private key is lost or leaked. */
static const unsigned char kk_lic_pub[64] = {
  0xa8, 0x33, 0x88, 0xd2, 0x64, 0x80, 0xc2, 0x70,
  0x23, 0x99, 0x98, 0x39, 0x19, 0x9b, 0x60, 0xee,
  0x1d, 0xf9, 0x9a, 0x25, 0xb4, 0xbd, 0x67, 0x5b,
  0xa1, 0xa2, 0x83, 0xe2, 0x15, 0x5f, 0xbc, 0xbd,
  0xd9, 0xd4, 0x03, 0x2c, 0xa2, 0x6e, 0xfd, 0x8a,
  0x37, 0x7c, 0x4d, 0x7c, 0x23, 0x56, 0x8e, 0x23,
  0x2d, 0x22, 0x8c, 0x99, 0x57, 0x30, 0x50, 0xe8,
  0xc0, 0x14, 0xfd, 0xe7, 0x6f, 0x57, 0x77, 0xaa
};

/* -1 for anything that is not a base32 digit. Dashes, spaces and newlines are
   dropped by the caller, so a typo lands here and fails the signature rather
   than being silently repaired. */
static int kk_lic_b32digit(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a';
  if (c >= '2' && c <= '7') return c - '2' + 26;
  return -1;
}

/* Returns the number of bytes decoded, or -1 on a bad character or overflow. */
static int kk_lic_b32decode(const char *s, kk_ssize_t slen,
                            unsigned char *out, int cap) {
  unsigned int acc = 0;
  int bits = 0, n = 0;
  kk_ssize_t i;
  for (i = 0; i < slen; i++) {
    char c = s[i];
    int d;
    if (c == '-' || c == ' ' || c == '\r' || c == '\n' || c == '\t' || c == '=')
      continue;
    d = kk_lic_b32digit(c);
    if (d < 0) return -1;
    acc = (acc << 5) | (unsigned int)d;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      if (n >= cap) return -1;
      out[n++] = (unsigned char)((acc >> bits) & 0xFF);
    }
  }
  return n;
}

/* SHA-256 then ECDSA P-256 verify, both through CNG -- no crypto of our own
   and no third-party library. */
static bool kk_lic_verify(const unsigned char *msg, int msglen,
                          const unsigned char *sig) {
  BCRYPT_ALG_HANDLE hash_alg = 0, ec_alg = 0;
  BCRYPT_KEY_HANDLE key = 0;
  unsigned char blob[8 + 64];
  unsigned char digest[32];
  NTSTATUS st;
  bool ok = false;

  /* BCRYPT_ECCKEY_BLOB: magic, then the key size, then X and Y. */
  *(ULONG *)(blob + 0) = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
  *(ULONG *)(blob + 4) = 32;
  memcpy(blob + 8, kk_lic_pub, 64);

  st = BCryptOpenAlgorithmProvider(&hash_alg, BCRYPT_SHA256_ALGORITHM, 0, 0);
  if (st != 0) goto done;
  st = BCryptHash(hash_alg, 0, 0, (PUCHAR)msg, (ULONG)msglen, digest, 32);
  if (st != 0) goto done;

  st = BCryptOpenAlgorithmProvider(&ec_alg, BCRYPT_ECDSA_P256_ALGORITHM, 0, 0);
  if (st != 0) goto done;
  st = BCryptImportKeyPair(ec_alg, 0, BCRYPT_ECCPUBLIC_BLOB, &key,
                           blob, sizeof(blob), 0);
  if (st != 0) goto done;

  st = BCryptVerifySignature(key, 0, digest, 32, (PUCHAR)sig, LIC_SIG_LEN, 0);
  ok = (st == 0);

done:
  if (key) BCryptDestroyKey(key);
  if (ec_alg) BCryptCloseAlgorithmProvider(ec_alg, 0);
  if (hash_alg) BCryptCloseAlgorithmProvider(hash_alg, 0);
  return ok;
}

/* The whole check in one FFI crossing: takes a key as typed, returns the
   licensee name, or "" if the key is not one we issued. The name comes back
   rather than a bool so the caller has something to show, and so a tampered
   name cannot be displayed -- it is covered by the signature. */
static kk_string_t kk_lic_check(kk_string_t key, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *s = kk_string_cbuf_borrow(key, &len, ctx);
  unsigned char buf[LIC_MAX];
  char name[LIC_NAME_MAX + 1];
  int n, namelen;
  kk_string_t res;

  n = kk_lic_b32decode(s, len, buf, LIC_MAX);
  kk_string_drop(key, ctx);

  namelen = n - LIC_HEAD_LEN - LIC_SIG_LEN;
  if (n < 0 || namelen <= 0 || namelen > LIC_NAME_MAX) return kk_string_empty();
  if (buf[0] != 1) return kk_string_empty();
  if (!kk_lic_verify(buf, LIC_HEAD_LEN + namelen, buf + LIC_HEAD_LEN + namelen))
    return kk_string_empty();

  memcpy(name, buf + LIC_HEAD_LEN, (size_t)namelen);
  name[namelen] = 0;
  res = kk_string_alloc_from_utf8(name, ctx);
  return res;
}

/* Days since 2020-01-01, or -1 for a key that does not verify. Not 0: that is
   a legitimate date, the day the epoch starts, and a key sold on it must not
   read as forged. Kept separate from the name so the common question -- is
   this licensed -- stays one call. */
static kk_integer_t kk_lic_day(kk_string_t key, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *s = kk_string_cbuf_borrow(key, &len, ctx);
  unsigned char buf[LIC_MAX];
  int n, namelen, day = -1;

  n = kk_lic_b32decode(s, len, buf, LIC_MAX);
  kk_string_drop(key, ctx);

  namelen = n - LIC_HEAD_LEN - LIC_SIG_LEN;
  if (n >= 0 && namelen > 0 && namelen <= LIC_NAME_MAX && buf[0] == 1 &&
      kk_lic_verify(buf, LIC_HEAD_LEN + namelen, buf + LIC_HEAD_LEN + namelen))
    day = (buf[1] << 16) | (buf[2] << 8) | buf[3];

  return kk_integer_from_int(day, ctx);
}
