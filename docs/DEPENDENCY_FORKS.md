# Vendored SSH dependencies

## Release readiness review — 2026-10-25

Upstream source and public advisory checks were repeated for the 1.0 candidate.
No dependency source or inventory was refreshed.

- Citadel upstream HEAD remains `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`.
  Its [public advisory page](https://github.com/orlandos-nl/Citadel/security/advisories)
  lists no published advisories.
- Joannis NIOSSH upstream HEAD remains
  `c997b6b12b8ef51a9b50701d98e3fab250d9a044`. Its public advisory API returned
  an empty array; the HTML advisory page could not be fetched.
- BigInt upstream HEAD is `63feef7820abb1a8fb08587d7da56bb0b7db8751`.
  The pinned base remains 5.7.0. Its
  [public advisory page](https://github.com/attaswift/BigInt/security/advisories)
  lists no published advisories; no source update was imported.
- [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)
  is available. This candidate retains the reviewed 2.9.6 source snapshot.
  The two August advisories
  [GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5)
  and [GHSA-4v99-qgq9-6pxp](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp)
  name 2.9.6 as their patched version. A 2.10 upgrade requires a separate
  source review and signed update qualification rather than an unreviewed
  last-minute dependency refresh.

The SSH forks cannot yet be retired: native key/agent and TLS-gateway
adaptations still rely on their local APIs. BigInt's local adaptation remains
a compiler deployment-floor adjustment; it has not been reimported here.
The Sparkle native project still uses the local Argument Parser snapshot.
Public advisory listings are not proof of absence of vulnerabilities.
For the free GitHub channel, updater qualification requires a real
older-to-newer installation between ad-hoc signed builds. The previous
notarized-update qualification plan applies only if a Developer ID channel is
introduced; it is not a prerequisite for the GitHub build. See
[distribution-specific update checks](SPARKLE.md).

## SFTP resource-boundary review — 2026-10-23

`git ls-remote` confirmed upstream HEAD remains `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`
for Citadel and `c997b6b12b8ef51a9b50701d98e3fab250d9a044` for Joannis NIOSSH.
Citadel's public advisory page lists no published advisories. The Joannis
advisory page could not be fetched, but its public GitHub security-advisories
API returned an empty array. This is not evidence of absence of unpublished
vulnerabilities. No upstream source was imported. The native-key and TLS gateway adaptations still
prevent replacing the local trees with the unmodified upstream packages.

Citadel now rejects SFTP packets above 8 MiB before buffering their payload.
Directory enumeration bounds canonicalization to 16 requests, READDIR responses
to 32,768, entries to 1,000,000 and accounted metadata to 64 MiB. Repeated
canonical paths are rejected. Successful enumeration closes its directory
handle; failure or cancellation closes the SFTP subsystem to release remote
handles and interrupt pending requests. The owning SSH transport is not closed.

## Tunnel keepalive review — 2026-10-22

The upstream GitHub source and security pages were rechecked before this
local change. Citadel's public advisory page listed no published advisories;
the Joannis advisory listing could not be fetched (cache miss), so its
advisory status remains unverified. No upstream source or version was imported.
Retiring the local trees was not attempted as part of this narrow correction.

- NIOSSH exposes one `sendKeepAlive` operation using its existing unknown
  global-request machinery. An explicit SSH request failure is a valid live
  response, not an authentication failure. No forwarding is allocated.
- Citadel exposes that operation with an event-loop deadline that closes an
  unresponsive transport. The application owns scheduling and cancellation.
  These are the only additional vendor adaptations for tunnel maintenance.

Review sources: [Citadel](https://github.com/orlandos-nl/Citadel),
[Citadel advisories](https://github.com/orlandos-nl/Citadel/security/advisories),
[NIOSSH](https://github.com/Joannis/swift-nio-ssh),
[NIOSSH security](https://github.com/Joannis/swift-nio-ssh/security).

## Source review — 2026-10-20

MacSCP compiles directly from versioned source directories. Adaptations are
permanent edits in those directories, not additional dependencies or patch
artifacts. Notices identify the original source version and retain its license.

| Directory | Original source | Base version | Base revision |
|---|---|---|---|
| `Vendor/citadel` | https://github.com/orlandos-nl/Citadel | 0.12.1 | `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` |
| `Vendor/swift-nio-ssh` | https://github.com/Joannis/swift-nio-ssh | 0.4.0 | `c997b6b12b8ef51a9b50701d98e3fab250d9a044` |

The Citadel tag is also upstream HEAD. The Joannis tag is the default
`citadel2` branch; Joannis is itself derived from Apple and is not covered by
the official-Apple vendoring exemption. Both dependencies are compiled from
the local reviewed sources. Source versions describe the imported bases,
not unmodified snapshots.

## Citadel: adaptations required by MacSCP

- `MacSCPECDSAKeyReader.swift` reads the P-256/P-384/P-521 OpenSSH keys selected
  by `SSHPrivateKeyLoader`, using the original container and bcrypt reader.
  It checks curve, point, scalar width/sign and private/public consistency.
  No additional Data-based initializer or key-type mismatch API is introduced.
- `MacSCPRSAAuthentication.swift` implements file-key RSA/SHA-2 authentication.
  It has no SHA-1 fallback option; the existing MacSCP loader tests pin both
  authentication offers and their `ssh-rsa` blob format.
- TLS gateway prehandlers are installed before SSH in `ClientSession.swift`.
  SFTP logging remains disabled.
- Existing Swift 6/NIO concurrency compatibility edits keep pipeline operations
  on their event loops and transfer metatypes/Sendable state, not handlers.
  The whole Citadel target is compiled, including server helpers.
- Manifests use the local NIOSSH/BigInt directories and exact trusted Apple
  versions; unused example/documentation dependencies are not built.

The original OpenSSH key container and certificate files have been restored
apart from the three key-type enum cases needed by the local ECDSA reader.
The inherited RSA/ECDSA implementation files and their three additional test files
are not retained. MacSCP's own key-loading/authentication tests remain.

## NIOSSH: adaptations required by MacSCP

- Local RSA host-key and ssh-agent/file-key adapters require distinct key-blob,
  host-key negotiation and user-authentication names (RFC 8332). The changes
  are limited to those protocol members and their negotiation/wire consumers.
- ECDSA component bounds checks prevent out-of-bounds signature parsing.
- SSH banner parsing accepts a server preamble without hashing it as the
  identification string; server-side parsing remains strict.
- Buffer reservations are compatible with the pinned NIO version and channel
  close handling avoids window updates after close.
- The optional AES-GCM sealed-box optimization has been removed. The existing
  Joannis custom-key API supplies the extensibility used by MacSCP.

## Compiler compatibility — 2026-10-20

NIOSSH future callbacks that touch handlers, authentication keys or connection
attributes use NIO's event-loop-isolated APIs. They enforce event-loop ownership
at runtime instead of declaring mutable handlers Sendable. Simple value metadata
has checked Sendable conformances. The algorithm registry stores metatypes only
and is accessed through one locked box; its narrow metadata-only Sendable
conformance does not apply to algorithm instances. Key/signature registration
is atomic. Sendable channel events retain their types rather than erasing to Any.

Citadel handles asynchronous exec-helper errors and clears handler state on the
owning loop before asynchronous termination. Pipe bootstrap uses the current
descriptor-ownership API. BigInt's unused watchOS deployment floor is raised to
the compiler-supported version. No warning-suppression flags are introduced.
Local development and packaging use the supported Swift Build engine instead
of the deprecated native engine.

Original licenses remain in each source directory. `scripts/check-vendor`
verifies the actual adapted sources; `THIRD_PARTY_NOTICES.md` contains licenses,
not an adaptation dependency graph.

GitHub's public advisory endpoints for orlandos-nl/Citadel and
Joannis/swift-nio-ssh returned empty arrays on 2026-10-20. This does not establish
absence of unpublished advisories or vulnerabilities. These source changes do
not prove a real remote connection; network/Keychain integration suites remain
separately gated.
