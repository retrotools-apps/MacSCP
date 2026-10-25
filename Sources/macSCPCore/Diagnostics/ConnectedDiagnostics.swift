import Foundation

public struct DiagnosticCollectionSettings: Sendable {
    public var systemInformation: Bool
    public var publicAddresses: Bool

    public init(systemInformation: Bool = true, publicAddresses: Bool = false) {
        self.systemInformation = systemInformation
        self.publicAddresses = publicAddresses
    }
}

/// Reads only the existing session. It never authenticates or disconnects
/// the supplied filesystem; those lifecycle decisions belong to its tab.
public enum ConnectedDiagnostics {
    public static func run(
        on filesystem: any RemoteFileSystem, directory: String,
        endpoint: Endpoint?, settings: DiagnosticCollectionSettings,
        appVersion: String, observer: DiagnosticRunObserver
    ) async -> DiagnosticReport {
        await collect(on: filesystem, directory: directory, endpoint: endpoint,
            settings: settings, appVersion: appVersion, observer: observer, accessProbe: { operation in
                let answer = await DetachedProbe.run(timeout: .seconds(5), operation)
                return answer.value == true
            })
    }

    /// Collection tests can execute the access operation deterministically;
    /// production retains its independently tested detached-probe deadline.
    static func collect(
        on filesystem: any RemoteFileSystem, directory: String,
        endpoint: Endpoint?, settings: DiagnosticCollectionSettings,
        appVersion: String, observer: DiagnosticRunObserver,
        accessProbe: @Sendable (_ operation: @escaping @Sendable () async -> Bool) async -> Bool
    ) async -> DiagnosticReport {
        var steps: [DiagnosticStep] = []
        func report() -> DiagnosticReport {
            DiagnosticReport(endpoint: endpoint, steps: steps, appVersion: appVersion,
                             completion: Task.isCancelled ? .cancelled(afterSteps: steps.count) : .complete)
        }
        guard !Task.isCancelled else { return report() }
        let timer = DiagnosticStepTimer(id: "session.access", titleKey: "diagnostics.step.sessionAccess")
        await observer.onStepStarted(timer.id, timer.titleKey)
        let answered = await accessProbe {
            do {
                if filesystem is any ServerInformationProvider { _ = try await filesystem.homeDirectoryPath() }
                else { _ = try await filesystem.stat(path: directory) }
                return true
            }
            catch { return false }
        }
        guard !Task.isCancelled else { return report() }
        let access = timer.finish(answered ? .ok : .failed(DiagnosticReason.connectionUnresponsive), "")
        steps.append(access)
        await observer.onStep(access)
        guard settings.systemInformation || settings.publicAddresses,
              let provider = filesystem as? any ServerInformationProvider else { return report() }
        let information = DiagnosticStepTimer(id: "server.information", titleKey: "diagnostics.step.serverInformation")
        await observer.onStepStarted(information.id, information.titleKey)
        let step: DiagnosticStep
        do {
            let result = try await provider.serverInformation(includePublic: settings.publicAddresses, includeSystem: settings.systemInformation, directory: directory)
            try Task.checkCancellation()
            var rows: [[String]] = []
            if settings.systemInformation {
                for (key, title) in [
                    ("os", "diagnostics.system.os"),
                    ("kernel", "diagnostics.system.kernel"),
                    ("uptime", "diagnostics.system.uptime"),
                    ("load", "diagnostics.system.load"),
                    ("memory", "diagnostics.system.memory"),
                    ("disk", "diagnostics.system.disk"),
                    ("users", "diagnostics.system.users")
                ] {
                    if let value = result.system[key] { rows.append([title, ServerSystemFormatting.value(value, field: key)]) }
                }
                let interfaces = Dictionary(grouping: result.local, by: \.interface)
                rows += interfaces.keys.sorted().map { [$0, interfaces[$0, default: []].map(\.address).joined(separator: "\n")] }
            }
            if settings.publicAddresses {
                rows.append(["diagnostics.system.public4", result.publicIPv4 ?? "—"])
                rows.append(["diagnostics.system.public6", result.publicIPv6 ?? "—"])
            }
            step = information.finish(rows.isEmpty ? .unavailable(DiagnosticReason.systemUnavailable) : .ok, "",
                                      table: DiagnosticTable(columns: ["diagnostics.system.field", "diagnostics.system.value"], rows: rows))
        } catch {
            guard !Task.isCancelled else { return report() }
            step = information.finish(.unavailable(DiagnosticReason.commandsUnavailable), "")
        }
        steps.append(step)
        await observer.onStep(step)
        return report()
    }

    public static func throughput(
        on filesystem: any RemoteFileSystem, settings: DiagnosticThroughputSettings,
        endpoint: Endpoint?, appVersion: String, observer: DiagnosticRunObserver
    ) async -> DiagnosticReport {
        guard !Task.isCancelled else {
            return DiagnosticReport(endpoint: endpoint, steps: [], appVersion: appVersion,
                                    completion: .cancelled(afterSteps: 0), scope: .throughput)
        }
        let timer = DiagnosticStepTimer(id: DiagnosticStepID.throughput,
                                        titleKey: DiagnosticStepID.titleKey(for: DiagnosticStepID.throughput))
        await observer.onStepStarted(timer.id, timer.titleKey)
        let step = await ThroughputProbe.measure(
            on: filesystem, payloadBytes: settings.payloadBytes,
            uploadThrottle: settings.uploadThrottle, downloadThrottle: settings.downloadThrottle,
            id: settings.fileID, cleanupBoundSeconds: settings.cleanupBoundSeconds,
            onProgress: observer.onThroughputProgress, timer: timer)
        let steps = !Task.isCancelled || ThroughputProbe.mayHaveLeftAFile(step) ? [step] : []
        for step in steps { await observer.onStep(step) }
        return DiagnosticReport(endpoint: endpoint, steps: steps, appVersion: appVersion,
                                completion: Task.isCancelled ? .cancelled(afterSteps: steps.count) : .complete,
                                scope: .throughput)
    }
}
