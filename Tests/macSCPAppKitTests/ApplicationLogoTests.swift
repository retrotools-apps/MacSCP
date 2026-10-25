import AppKit
import CryptoKit
import MacSCPTestSupport
import SwiftUI
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("Compressed application logo catalogue")
@MainActor
struct ApplicationLogoTests {
    @Test func shippedCatalogueExcludesTheRestrictedTermsChosenByTheUser() throws {
        let url = try #require(L10n.bundle.url(forResource: "ApplicationLogos", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["includesRestricted"] as? Bool == false)
        #expect(root["licensePolicy"] as? String == "permissive-and-cc0")
        let records = try #require(root["icons"] as? [[String: Any]])
        #expect(records.contains { $0["id"] as? String == "mysql" })
        #expect(root["providerExceptions"] == nil)
        let providers = try #require(root["additionalProviders"] as? [String: [String: Any]])
        #expect(providers["tabler-icons"]?["license"] as? String == "MIT")
        for record in records {
            if record["origin"] as? String == "macscp-original" {
                #expect(["php", "jenkins", "internetbox", "ghost-mascot", "esxi"].contains(record["id"] as? String ?? ""))
                continue
            }
            let licence = (record["license"] as? [String: Any])?["type"] as? String ?? "CC0-1.0"
            #expect(["CC0-1.0", "Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "0BSD", "ISC", "Unlicense"].contains(licence))
        }
        #expect(records.contains { $0["origin"] as? String == "macscp-original" })
    }
    @Test func everyCompressedSVGMatchesItsBundledDigest() throws {
        #expect(!ApplicationLogo.catalogue.isEmpty)
        #expect(Set(ApplicationLogo.catalogue.map(\.id)).count == ApplicationLogo.catalogue.count)
        for record in ApplicationLogo.catalogue {
            let svg = try #require(ApplicationLogo.svgData(id: record.id))
            let digest = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
            #expect(digest == record.sha256)
        }
        #expect(ApplicationLogo.svgData(id: "../../outside") == nil)
        #expect(ApplicationLogo.image(id: "not-a-catalogue-logo") == nil)
    }

    @Test func onlyReviewedNetworkDevelopmentAndOperatingSystemIconsAreBundled() throws {
        let path = SourceCorpus.url(of: .sources).deletingLastPathComponent()
            .appendingPathComponent("scripts/application-icon-scope.json")
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let categories = try #require(document["categories"] as? [String: [String]])
        let allowed = Set(categories.values.flatMap { $0 })
        let bundled = Set(ApplicationLogo.catalogue.map(\.id))
        #expect(!allowed.isEmpty)
        let tabler = Set(ApplicationLogo.catalogue.filter { $0.origin == "tabler-icons" }.map(\.id))
        #expect(Set(ApplicationLogo.catalogue.map(\.id)) == allowed.union(tabler))
        #expect(!tabler.isEmpty)
        #expect(["architecture-cloud", "architecture-database", "architecture-firewall-check",
                 "architecture-load-balancer", "architecture-topology-complex"].allSatisfy(tabler.contains))
        #expect(ApplicationLogo.catalogue.allSatisfy { $0.origin != "aws-architecture" })
        #expect(ApplicationLogo.catalogue.allSatisfy { !$0.id.hasPrefix("aws-") })
        #expect(["vmware", "mysql", "apachetomcat", "php", "jenkins", "macos", "linux", "wireshark", "mqtt"].allSatisfy(bundled.contains))
        for irrelevant in ["aldinord", "aldisud", "laposte", "deutschepost", "bmw", "aeroflot", "nike", "mcdonalds", "netflix", "spotify"] {
            #expect(!bundled.contains(irrelevant))
            #expect(ApplicationLogo.svgData(id: irrelevant) == nil)
            #expect(AppearanceCatalogue.entries(matching: irrelevant).isEmpty)
        }
    }

    @Test func unlicensedProviderArtworkIsNotBundled() {
        #expect(ApplicationLogo.catalogue.allSatisfy { $0.origin != "aws-architecture" })
        #expect(ApplicationLogo.svgData(id: "aws-service-amazon-ec2") == nil)
        #expect(ApplicationLogo.catalogue.contains { $0.origin == "tabler-icons" })
    }

    @Test func everyCatalogueIconRendersAtSidebarAndPickerSizes() throws {
        for record in ApplicationLogo.catalogue {
            if ProcessInfo.processInfo.environment["CORESVG_VERBOSE"] != nil {
                FileHandle.standardError.write(Data("Rendering catalogue icon: \(record.id)\n".utf8))
            }
            let image = try #require(ApplicationLogo.image(id: record.id))
            for size in [16, 32] {
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                let pixels = try #require(bitmap.bitmapData)
                let hasArtwork = (0..<size).contains { y in
                    (0..<size).contains { x in pixels[y * bitmap.bytesPerRow + x * 4 + 3] != 0 }
                }
                #expect(hasArtwork, "Empty icon: \(record.id) at \(size)px")
            }
        }
    }

    @Test(arguments: ["vmware", "kibana", "redis", "mysql", "apache", "php", "apachetomcat",
                      "nginx", "postgresql", "mongodb", "elasticsearch", "grafana", "prometheus",
                      "docker", "kubernetes", "gitlab", "jenkins", "internetbox", "ghost-mascot", "esxi"])
    func catalogueArtworkDecodesAsTintableVectorImages(id: String) throws {
        let image = try #require(ApplicationLogo.image(id: id))
        #expect(image.isValid)
        #expect(image.isTemplate)
    }

    @Test func searchFindsNamesAndSlugsWithoutCaseSensitivityAndHasAnEmptyState() {
        #expect(AppearanceCatalogue.entries(matching: "MYSQL").contains { $0.logo == "mysql" })
        #expect(AppearanceCatalogue.entries(matching: "tomcat").contains { $0.logo == "apachetomcat" })
        #expect(AppearanceCatalogue.entries(matching: "vmware").contains { $0.logo == "vmware" })
        #expect(AppearanceCatalogue.entries(matching: "ESXi").contains { $0.logo == "esxi" })
        #expect(!AppearanceCatalogue.entries(matching: "ESXi").contains { $0.logo == "vmware" })
        #expect(AppearanceCatalogue.entries(matching: "box").contains { $0.logo == "internetbox" })
        #expect(AppearanceCatalogue.entries(matching: "fantôme").contains { $0.logo == "ghost-mascot" })
        #expect(!AppearanceCatalogue.entries(matching: "EC2").contains { $0.logo?.hasPrefix("aws-") == true })
        #expect(AppearanceCatalogue.entries(matching: "load balancer").contains {
            $0.logo == "architecture-load-balancer"
        })
        #expect(AppearanceCatalogue.entries(matching: "no-such-logo-in-the-catalogue").isEmpty)
    }

    @Test func esxiDeviceRoleDoesNotRenderTheVMwareWordmark() throws {
        #expect(ApplicationLogo.resourceName(for: .vmwareESXi) == "esxi")
        #expect(ApplicationLogo.resourceName(for: .internetBox) == "internetbox")
        #expect(ApplicationLogo.resourceName(for: .ghost) == "ghost-mascot")
        for icon: SessionAppearance.Icon in [.vmwareESXi, .internetBox, .ghost] {
            #expect(try #require(ApplicationLogo.image(for: icon)).isTemplate)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], ["MySQL", "PHP", "Jenkins", "ESXi", "fantôme", "internetbox"])
    func searchResultsRenderWithTheCatalogueArtwork(scheme: ColorScheme, query: String) async throws {
        let view = AppearanceCataloguePicker(appearance: .constant(.init(tint: .teal, applicationLogo: "mysql")),
            kind: .ssh, onSelect: {}, search: query).environment(\.colorScheme, scheme)
        #expect(try #require(ImageRenderer(content: view).nsImage).isValid)
    }
}
