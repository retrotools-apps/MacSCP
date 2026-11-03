import Foundation
import Testing
@testable import macSCPCore

@Suite("ExportEnvelopeCodec")
struct ExportEnvelopeCodecTests {
    private struct Probe: Codable, Equatable { var name: String; var count: Int }

    @Test func roundTripsClearAndEncryptedPayloads() throws {
        let payload = Probe(name: "x", count: 3)
        for password in [nil, "pw"] as [String?] {
            let data = try ExportEnvelopeCodec.encode(
                payload, format: "macscp-probe", version: 1, password: password)
            #expect(try ExportEnvelopeCodec.probe(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1)
                == (password != nil))
            #expect(try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1,
                password: password) == payload)
        }
    }

    @Test func encryptedEnvelopeDoesNotExposePayload() throws {
        let data = try ExportEnvelopeCodec.encode(
            Probe(name: "private", count: 3), format: "macscp-probe", version: 1,
            password: "pw")
        #expect(!String(decoding: data, as: UTF8.self).contains("private"))
    }

    @Test func rejectsForeignFormatAndFutureVersion() throws {
        let foreign = try ExportEnvelopeCodec.encode(
            Probe(name: "x", count: 1), format: "macscp-probe", version: 1,
            password: nil)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try ExportEnvelopeCodec.decode(
                foreign, as: Probe.self, format: "macscp-other", currentVersion: 1,
                password: nil)
        }
        let future = try ExportEnvelopeCodec.encode(
            Probe(name: "x", count: 1), format: "macscp-probe", version: 2,
            password: nil)
        #expect(throws: SessionExportError.unsupportedVersion(2)) {
            _ = try ExportEnvelopeCodec.probe(
                future, as: Probe.self, format: "macscp-probe", currentVersion: 1)
        }
    }

    @Test(arguments: [-1, 0, 5_000_000_000])
    func hostileIterationCountsAreRejectedBeforeKeyDerivation(override: Int) throws {
        let data = try ExportEnvelopeCodec.encode(
            Probe(name: "x", count: 1), format: "macscp-probe", version: 1,
            password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["iterations"] = override
        let hostile = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try ExportEnvelopeCodec.decode(
                hostile, as: Probe.self, format: "macscp-probe", currentVersion: 1,
                password: "pw")
        }
    }

    @Test func wrongPasswordFailsWithoutOracle() throws {
        let data = try ExportEnvelopeCodec.encode(
            Probe(name: "x", count: 1), format: "macscp-probe", version: 1,
            password: "right")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1,
                password: "wrong")
        }
    }
}
