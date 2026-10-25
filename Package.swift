// swift-tools-version:6.0
import PackageDescription
import Foundation

let storeBuild = ProcessInfo.processInfo.environment["MACSCP_DISTRIBUTION"] == "app-store"
let withSparkle = !storeBuild && ProcessInfo.processInfo.environment["MACSCP_ENABLE_SPARKLE"] == "1"
let sparklePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/sparkle/Build/Products/Release").path
let appSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
    + (storeBuild ? [.define("MACSCP_APP_STORE")] : [])
    + (withSparkle ? [.define("MACSCP_SPARKLE"), .unsafeFlags(["-F", sparklePath])] : [])
let sparkleLinkSettings: [LinkerSetting] = withSparkle
    ? [.unsafeFlags(["-F", sparklePath, "-framework", "Sparkle", "-Xlinker", "-rpath",
                     "-Xlinker", "@executable_path/../Frameworks"]),
       .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sparklePath], .when(configuration: .debug))] : []

let package = Package(
    name: "macSCP",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "macSCPCore", targets: ["macSCPCore"]),
        .executable(name: "MacSCP", targets: ["MacSCPMain"]),
    ],
    // Non-Apple dependencies use local sources. Official Apple packages use
    // exact versions and the committed root Package.resolved revision lock.
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        // Original Citadel/Joannis sources with only MacSCP-required adaptations.
        // These directories are compiled directly; there is no patch replay step.
        .package(path: "Vendor/citadel"),
        .package(path: "Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
        .package(path: "Vendor/bigint"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.2"),
    ],
    targets: [
        .target(
            name: "macSCPCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // Core implements NIOSSH's key/signature protocols itself
                // (AgentBackedPrivateKey); naming the product here is what
                // makes the root-level swift-nio-ssh dependency "used".
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                // RSA host-key verification (`RSASHA2HostKey`): PKCS#1 v1.5
                // over SHA-512 lives in `_RSA.Signing`, which `Crypto` does
                // not vend.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                // `PEMPrivateKeyDecoder` reads DER with it.
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/pl.lproj"),
                .process("Resources/es.lproj"),
                .process("Resources/ro.lproj"),
                .process("Resources/it.lproj"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)] + (storeBuild ? [.define("MACSCP_APP_STORE")] : [])
        ),
        .target(
            name: "MacSCPAppKit",
            dependencies: [
                "macSCPCore",
            ],
            resources: [.process("Resources")],
            swiftSettings: appSettings,
            linkerSettings: sparkleLinkSettings
        ),
        .executableTarget(
            name: "MacSCPMain",
            dependencies: ["MacSCPAppKit", "macSCPCore"],
            swiftSettings: appSettings
        ),
        // Shared by both test targets, which cannot share a source file
        // (SwiftPM compiles each target from its own directory). It imports
        // no test library, so it is a plain target; the two test targets
        // depend on it.
        .target(
            name: "MacSCPTestSupport",
            dependencies: [
                // `AwaitCancellably.swift` awaits an `EventLoopFuture`
                // through `whenComplete` under a `NIOLockedValueBox`
                // instead of the cancellation-blind `EventLoopFuture.get()`
                // (docs/BACKLOG.md, "Wall-clock ceilings still in the
                // tree"). Both test targets already carried NIOCore
                // transitively through `macSCPCore`; this is the first
                // direct use from a plain (non-test) target.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/MacSCPTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "macSCPAppKitTests",
            dependencies: ["MacSCPAppKit", "MacSCPTestSupport"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "macSCPCoreTests",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                "macSCPCore",
                "MacSCPTestSupport",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                // `RSASHA2HostKeyTests` parses a host-key blob into
                // `ByteBuffer` and hands the result to NIOSSH's key/signature
                // protocols directly.
                .product(name: "NIOCore", package: "swift-nio"),
                // `SSHPrivateKeyLoaderTests` drains a built
                // `SSHAuthenticationMethod` the way NIOSSH does, on a real
                // event loop, to read the algorithm names it would offer.
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                // `PEMPrivateKeyDecoderTests` builds a PBES2 file and a
                // PKCS#8 wrapper with `DER.Serializer`, derives the PBKDF2 key
                // the file declares, and checks the RSA primes with
                // arbitrary-precision arithmetic. All three modules reach the
                // test target through the graph anyway; they are named here so
                // an import in this target rests on a declaration rather than
                // on which module happened to be built next door.
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            // `LegacyStoreCompatibilityTests` copies these into a temporary
            // directory and loads them through the real stores, addressing
            // them by `#filePath` — so they must NOT be bundled as resources.
            // Declaring them keeps SwiftPM from warning about unhandled files.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
