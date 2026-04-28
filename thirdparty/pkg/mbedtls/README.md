# mbedtls

Mbed TLS C library package for embed-zig.

The build fetches official upstream Mbed TLS `4.1.0` and the matching
TF-PSA-Crypto `1.1.0` release archives and compiles them as a static C library.
The package is exported as the independent top-level module `mbedtls`; if user
code does not import that module, the library is not pulled into the final
artifact.

License note: upstream Mbed TLS is dual licensed under Apache-2.0 OR
GPL-2.0-or-later. The source is fetched from upstream rather than vendored here.

Crypto wrappers are PSA-first. Mbed TLS 4 removed or privatized many 3.x
primitive headers (`mbedtls/aes.h`, `mbedtls/sha256.h`, `mbedtls/ecp.h`,
`mbedtls/rsa.h`, and related APIs), so this package does not provide legacy
compatibility shims for those surfaces.

Ed25519 note: TF-PSA-Crypto 1.1.0 exposes PSA EdDSA algorithm identifiers, but
the upstream headers still document Edwards curves as unsupported. This package
therefore exposes `features.psa.ed25519 = false` and does not provide an
Ed25519 wrapper.

Public Zig wrappers are split into a thin binding layer and the stable crypto
facade:

- `src/binding/` exposes the C import, feature flags, version helpers, status
  mapping, and the low-level PSA key/sign/MAC/agreement helpers.
- `src/{aead,core,dh,ecc,hash,kdf,mac,sign}` implement the runtime-facing crypto
  shapes directly on Mbed TLS/PSA, with `src/Certificate.zig` covering X.509
  certificate parsing and signature verification for the runtime TLS stack.
- `src/crypto.zig` is the crypto namespace exported by `mbedtls.crypto`.
- Local C binding helpers live under `src/binding/binding.c` and are used only
  for public PSA operation types that are opaque to Zig cimport.

Current crypto facade coverage includes SHA-256/384/512, HMAC-SHA-2, AES-GCM,
ChaCha20-Poly1305, HKDF-SHA-2, ECDSA P-256/P-384, X25519, P-256/P-384 ECDH
point multiplication, AES-128/256 block operations, and certificate
authentication helpers for ECDSA/RSA X.509 chains. Unsupported algorithms are
omitted rather than filled with `std.crypto` implementations.
