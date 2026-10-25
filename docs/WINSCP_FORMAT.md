# WinSCP INI interoperability

## Scope and provenance

Reviewed against the official WinSCP repository on 2026-10-19, revision
`24e7b4ec1001406cc2edf2b8c88483d66d4449d8`:

- [Cryptography.cpp](https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/source/core/Cryptography.cpp): cipher, password scrambling and verifier layout.
- [Security.cpp](https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/source/core/Security.cpp): external-password marker and legacy per-session obfuscation.
- [WinConfiguration.cpp](https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/source/windows/WinConfiguration.cpp): master-password verification and encrypted-secret lifecycle.
- [SessionData.cpp](https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/source/core/SessionData.cpp) and [HierarchicalStorage.cpp](https://github.com/winscp/winscp/blob/24e7b4ec1001406cc2edf2b8c88483d66d4449d8/source/core/HierarchicalStorage.cpp): session fields and INI string encoding.

The implementation is independently written Swift, using Apple CommonCrypto,
CryptoKit and Security. No WinSCP executable, runtime library, source tree or
new package dependency is shipped. The fixed scrambling permutation is file
format data required to interpret WinSCP credentials.

## Cryptographic format

`UseMasterPassword=1` and a valid `MasterPasswordVerifier` are required even
if individual legacy-obfuscated records coexist in the file. The master
password is UTF-8. PBKDF2-HMAC-SHA1 uses 1000 iterations and a 16-byte random
salt, deriving 66 bytes: 32 for AES-256, 32 for HMAC, and two unused verifier
bytes. AES uses counter blocks starting at one, incrementing the first eight
bytes little-endian; this is not standard big-endian AES-CTR.

Each secret is scrambled to WinSCP's length/padding/permutation representation
before encryption. Stored secrets have the `A35D` external marker, followed
by hexadecimal `salt || ciphertext || HMAC-SHA1(ciphertext)[0..<10]`.
Authentication is checked before decryption; tag comparisons do not exit on
the first differing byte. The master verifier stores `salt || dummy || tag`,
where the tag authenticates encryption of the 16-byte random dummy.

The iteration count and truncated SHA-1 MAC are compatibility constraints,
not recommended parameters for a new format. Server metadata is not covered
by these MACs. Secrets are plaintext temporarily in process memory to migrate
them into Keychain or encrypt them for export; Swift strings cannot promise
forensic memory erasure. Sheet/job references are released on cancellation,
dismissal and completion. No plaintext temporary file is created.

## Verification and limitations

Tests include independent vectors produced with Python's standard
`hashlib.pbkdf2_hmac`/HMAC and OpenSSL AES-ECB over little-endian counter blocks,
including a Unicode master password and secret. They verify encryption,
decryption, scrambling, wrong-password/tamper refusal, mandatory protection,
encrypted export/import, folders, jump credentials, unsafe-route exclusion,
INI escaping and input limits. The original user INI is used only for an
explicit read-only structural check, never as a committed fixture and never
decrypted without a password entered by its owner.

These checks establish algorithm/format interoperability, not a completed
round trip through a running Windows WinSCP instance. That application-level
check remains a manual validation. Unrepresentable routes and secrets are
refused rather than silently dropped; see the README for supported settings.
