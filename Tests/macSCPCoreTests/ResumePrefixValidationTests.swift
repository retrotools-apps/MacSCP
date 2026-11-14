import Foundation
import Testing
@testable import macSCPCore

struct ResumePrefixValidationTests {
    @Test func intactPartialPrefixMatchesWithoutReadingTheWholeSource() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = MockRemoteFileSystem(files: ["/source": data])
        let destination = MockRemoteFileSystem(files: ["/partial": data.prefix(90_137)])
        let matches = try await ResumePrefixValidation.matches(source: source, sourcePath: "/source",
            destination: destination, destinationPath: "/partial", count: 90_137)
        #expect(matches)
    }

    @Test(arguments: [0, 32_000, 65_536, 90_136])
    func holeInPartialPrefixRejectsSizeBasedResume(hole: Int) async throws {
        let data = Data((0..<90_137).map { UInt8($0 % 251) })
        var damaged = data
        damaged[hole] ^= 0xff
        let source = MockRemoteFileSystem(files: ["/source": data])
        let destination = MockRemoteFileSystem(files: ["/partial": damaged])
        let matches = try await ResumePrefixValidation.matches(source: source, sourcePath: "/source",
            destination: destination, destinationPath: "/partial", count: UInt64(data.count))
        #expect(!matches)
    }

    @Test func prematurelyEndedPrefixIsNotTrusted() async throws {
        let source = MockRemoteFileSystem(files: ["/source": Data([1, 2, 3])])
        let destination = MockRemoteFileSystem(files: ["/partial": Data([1, 2])])
        let matches = try await ResumePrefixValidation.matches(source: source, sourcePath: "/source",
            destination: destination, destinationPath: "/partial", count: 3)
        #expect(!matches)
    }
}
