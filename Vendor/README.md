# Dependency sources and trust policy

The Swift dependencies versioned here are BigInt, Citadel and
swift-nio-ssh. Citadel comes from orlandos-nl/Citadel 0.12.1; NIOSSH comes
from Joannis/swift-nio-ssh 0.4.0. Required MacSCP adaptations are implemented
directly in these sources. There are no patch-file dependencies or replay
steps. Their original licenses are preserved in THIRD_PARTY_NOTICES.md.
See `docs/DEPENDENCY_FORKS.md` for the dated source review.

Sparkle and its signing-tool dependency, Apple Argument Parser, are also
vendored as native build sources. `native-dependencies.json` records their
immutable provenance; neither is a root SwiftPM dependency. Sparkle is built
locally, never consumed as a binary package target. See `docs/SPARKLE.md`.

Package manifests use local paths for these dependencies. Unused
example/documentation packages are omitted from manifests; example sources
remain. Snapshot ignore files include a final inclusion rule.

The eight trusted official Apple packages are swift-asn1, swift-atomics,
swift-collections, swift-crypto, swift-log, swift-nio, swift-system and
swift-nio-ssl. They are exempt from vendoring and dependency source auditing.
SwiftPM consumes them from their official repositories, with exact manifest
versions and a committed root Package.resolved revision lock. Initial
resolution requires network access or a populated cache.

Vendor/Package.resolved records imported source provenance, not the complete
adapted file contents. Vendor/checksums.json records those contents, symlinks
and executable modes. Run `scripts/check-vendor` before building. CI and
packaging reject inventory changes, unapproved remote/registry/binary
packages, escaping paths and Apple lock drift.

## Updates

1. Review original source changes, licenses and public security advisories
   before importing an exact revision.
2. Implement only adaptations required by MacSCP in Vendor, preserving
   licenses and local-path/exact-Apple manifests.
3. Review the actual changes, then run `scripts/check-vendor --record`.
   The inventory establishes integrity, not absence of malicious code.
4. Regenerate notices and run policy, compilation and regression checks.

Compiler, SDK, CI, signing keys and trusted Apple repositories remain
supply-chain trust boundaries.
