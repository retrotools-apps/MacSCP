# Direct-distribution updates

Sparkle 2.9.6 is imported from revision
`ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`. Its upstream binary SwiftPM
manifest and upstream resolution lock are omitted: MacSCP builds the native
framework and signing tools from source. The Xcode project uses the adjacent,
local Apple Argument Parser 0.4.4 source snapshot, matching upstream's lock.
No updater binaries are fetched during a build.

## Source review (2026-10-23)

Reviewed upstream release/security notes through 2.9.6, its MIT/BSD/zlib
notices, framework/tool build phases, update verification settings and standard
controller API. Version 2.9.6 includes installer archive-handling and root-user
fixes. MacSCP does not run its updater as root. This is a focused integration
review, not an exhaustive audit of Sparkle or a production update test.

Sources: <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6>,
<https://sparkle-project.org/documentation/security-and-reliability/>,
<https://sparkle-project.org/documentation/>.

The only native-project adaptation replaces its remote Argument Parser
reference with a local source path. Runtime updater source is unchanged.
The dependency inventory covers both native source trees. Updates require
an explicit review and inventory refresh, just like the Swift dependencies.

## Building

`bash scripts/build-sparkle --tools` builds the universal framework and its
release tools using Xcode. `scripts/package-app` embeds it by default. A plain
`swift build` remains usable without Sparkle; enable linking for a source
build with `MACSCP_ENABLE_SPARKLE=1 swift build` after building the framework.
The framework must be embedded and signed before running a packaged copy.
For a signed bare development executable, `MACSCP_ENABLE_SPARKLE=1 scripts/dev build`
also signs the source-built framework and its nested helpers with the configured
identity. This preserves hardened-runtime library validation. Such bare launches
still cannot install updates; updater startup requires a packaged application.

## Keys and publishing

The public key is in `Resources/Sparkle-public-key.txt`. Sparkle's key tool
stores the matching private key in the login Keychain; the configured account
is `retroTools.MacSCP.updates`.
Never commit or print it. Back it up securely outside the repository before
changing machines; only the maintainer should perform private-key export.

Local releases use the Keychain. GitHub Actions requires the matching private
key to be configured manually as the `MACSCP_SPARKLE_PRIVATE_KEY` repository
secret. The workflow passes it to the signing tool through standard input,
not command-line arguments. This integration does not export the local key
or configure a GitHub secret automatically.

Before compiling, the release workflow checks the export format and its public
key match. After building Sparkle, it signs a small probe and verifies that
signature with CryptoKit. Store exclusion runs in parallel with the GitHub
build; publication waits for both. Compilation outputs are cached by toolchain
and source inputs, but private keys, signing diagnostics and final signed feeds
are never cached. The DMG is retained as a short-lived workflow artifact before
feed generation, so a signing failure does not discard the expensive build.
No already published release or update-signing public key is replaced.

The GitHub distribution is free: `bash scripts/release` creates a DMG with an
ad-hoc signed application and no Apple notarization. This path does not require
Developer ID credentials. The explicit `--ad-hoc` signing mode grants no
restricted Keychain entitlements and does not enable hardened-runtime library
validation, which would reject ad-hoc signed frameworks. Standard Keychain
storage remains available; the existing biometric-protection eligibility check
continues to require an Apple-signed identity. Previously protected credentials
are not silently downgraded or migrated.

`bash scripts/generate-appcast` generates a signed `dist/appcast.xml` from only
the current release DMG. A public-key-only CryptoKit verifier checks the feed
signature, archive signature, length, URL and application version before the
feed can be published. Missing or mismatched signatures stop publication.
The release workflow publishes both
files, with GitHub provenance attestations for their exact final bytes. It
refuses to replace an already published version. Public-repository attestations
require no personal signing certificate. The application reads the stable release's `appcast.xml` asset and
downloads the archive from its version-specific release URL. Pre-releases
do not replace GitHub's latest stable release. Use monotonically increasing
`CFBundleVersion` values; CI uses its run number as `MACSCP_BUILD`.

Automatic checks default on; silent installation and system profiling are
disabled. Signed feeds and archive verification before extraction are
mandatory, with no unsigned-feed timeout fallback. Installation uses
Sparkle's standard confirmation and relaunch flow, which must be tested
against two real ad-hoc signed packaged versions before claiming end-to-end
qualification of the free GitHub channel. Unit tests and valid signatures alone
do not demonstrate a successful installation or preserve Keychain access across
an update. Initial installation may require macOS's per-app approval; GitHub
attestations do not bypass Gatekeeper.

## Separate Store build

`MACSCP_DISTRIBUTION=app-store scripts/package-app` excludes Sparkle at compile,
link and packaging time. Its updates must come from the Store, never this feed.
The GitHub release script and ad-hoc signing mode reject Store packages.
Store signing, sandbox qualification and submission remain separate work;
excluding Sparkle alone does not make a Store-ready submission.
