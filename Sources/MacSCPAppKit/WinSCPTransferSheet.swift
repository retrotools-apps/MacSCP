import Foundation
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

enum WinSCPTransferAction: String, Identifiable {
    case importFile, exportFile
    var id: String { rawValue }
}

private struct WinSCPDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Master passwords and decrypted previews live only in this sheet. The
/// caller applies a confirmed import after dismissal, using the normal
/// conflict planner and Keychain writer; this view never connects anywhere.
struct WinSCPTransferSheet: View {
    let action: WinSCPTransferAction
    let sessions: SessionListViewModel
    var initialFileData: Data? = nil
    var initialFileName = ""
    var exportSessionIDs: Set<UUID>? = nil
    let onImport: (SessionExportPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var selected: Set<UUID> = []
    @State private var fileData: Data?
    @State private var fileName = ""
    @State private var preview: WinSCPINICodec.ImportResult?
    @State private var showPicker = false
    @State private var document: WinSCPDocument?
    @State private var showExporter = false
    @State private var errorMessage: String?
    @State private var job: Task<Void, Never>?
    @State private var busy = false

    private var isImport: Bool { action == .importFile }
    private var exportCandidates: [StoredSession] {
        sessions.sessions.filter { exportSessionIDs?.contains($0.id) ?? true }
    }
    private var title: String { isImport ? L10n.string("winscp.import", "Import WinSCP.ini…") : L10n.string("winscp.export", "Export WinSCP.ini…") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text(L10n.string("winscp.scope", "SSH/SFTP connections, folders and SSH jump hosts. Unsupported proxies, commands and TLS gateways are not converted. UI preferences and starting directories are not imported. Key files are never copied. Encrypted private-key passphrases cannot be exported in this version."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isImport {
                if initialFileData == nil {
                    Button(L10n.string("winscp.choose", "Choose WinSCP.ini…")) { showPicker = true }
                        .disabled(busy)
                }
                if !fileName.isEmpty { Text(fileName).font(.caption) }
            }
            if preview == nil {
                SecureField(L10n.string("winscp.master", "Master password (required)"), text: $password)
                    .disabled(busy)
                if !isImport {
                    SecureField(L10n.string("winscp.repeat", "Confirm master password"), text: $repeatedPassword)
                        .disabled(busy)
                }
            }
            if let preview {
                Text(String(format: L10n.string("winscp.preview %d %d", "%d supported sessions; %d unsupported sessions excluded."),
                            preview.payload.sessions.count, preview.skippedNames.count))
                List {
                    ForEach(preview.payload.sessions, id: \.id) { session in
                        HStack {
                            Toggle(session.name, isOn: selection(session.id))
                            Spacer()
                            let fields = FieldValues(raw: session.fields)
                            Text(fields[SSHField.host] + ":" + fields[SSHField.port])
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(Array(preview.skippedNames.enumerated()), id: \.offset) { _, name in
                        Text(name + " — " + L10n.string("winscp.notSupported", "Not supported"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !isImport {
                List(exportCandidates) { session in
                    Toggle(session.name, isOn: selection(session.id))
                        .disabled(!WinSCPINICodec.supportsExport(session, sessions: sessions.sessions) || busy)
                        .help(WinSCPINICodec.supportsExport(session, sessions: sessions.sessions)
                              ? L10n.string("winscp.withSecrets", "Stored secrets are always included and encrypted.")
                              : L10n.string("winscp.notSupported", "Not supported"))
                }
            } else { Spacer(minLength: 0) }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if let preview {
                    Button(L10n.string("winscp.confirmImport", "Import selected sessions")) {
                        let payload = WinSCPINICodec.selecting(selected, from: preview.payload)
                        onImport(payload)
                        dismiss()
                    }
                    .disabled(selected.isEmpty || busy)
                    .buttonStyle(.polishedProminent)
                } else {
                    Button(isImport ? L10n.string("winscp.unlock", "Unlock and preview") : L10n.string("winscp.export", "Export WinSCP.ini…")) {
                        if isImport { unlock() } else { export() }
                    }
                    .disabled(busy || password.isEmpty || (isImport ? fileData == nil : selected.isEmpty || password != repeatedPassword))
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 680, height: 580)
        .onAppear {
            if let initialFileData {
                fileData = initialFileData
                fileName = initialFileName
            }
            if !isImport {
                selected = Set(exportCandidates.filter {
                    WinSCPINICodec.supportsExport($0, sessions: sessions.sessions)
                }.map(\.id))
            }
        }
        .onDisappear {
            job?.cancel()
            job = nil
            password = ""
            repeatedPassword = ""
            preview = nil
            fileData = nil
            document = nil
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let bytes = try file.read(upToCount: WinSCPINICodec.maximumFileSize + 1) ?? Data()
                guard bytes.count <= WinSCPINICodec.maximumFileSize else { throw WinSCPINIError.invalid }
                fileData = bytes
                fileName = url.lastPathComponent
                preview = nil
                password = ""
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $showExporter, document: document, contentType: .data, defaultFilename: "WinSCP.ini") { result in
            document = nil
            if case .failure = result { errorMessage = L10n.string("winscp.writeFailed", "Could not save the encrypted WinSCP file.") }
            else { dismiss() }
        }
    }

    private func selection(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private func unlock() {
        guard let bytes = fileData else { return }
        let master = password
        busy = true
        errorMessage = nil
        job = Task { @MainActor in
            do {
                let result = try await WinSCPBackgroundWork.run { try WinSCPINICodec.decode(bytes, masterPassword: master) }
                guard !Task.isCancelled else { return }
                preview = result
                selected = Set(result.payload.sessions.map(\.id))
                password = ""
                fileData = nil
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            busy = false
        }
    }

    private func export() {
        do {
            // Read only the selected sessions' secrets, through the existing
            // login-set/jump/managed-key resolver, never from raw JSON.
            var payload = SessionExportPayload(includesSecrets: true, groups: [], sessions: [])
            var groupIDs: Set<UUID> = []
            for session in sessions.sessions where selected.contains(session.id) {
                let part = sessions.exportPayload(for: .single(session), includeGroups: true, includePasswords: true)
                guard part.missingPasswordCount == 0 else { throw WinSCPINIError.missingSecret }
                payload.sessions += part.payload.sessions
                payload.groups += part.payload.groups.filter { groupIDs.insert($0.id).inserted }
            }
            let captured = payload
            let master = password
            busy = true
            errorMessage = nil
            job = Task { @MainActor in
                do {
                    let data = try await WinSCPBackgroundWork.run { try WinSCPINICodec.encode(captured, masterPassword: master) }
                    guard !Task.isCancelled else { return }
                    password = ""
                    repeatedPassword = ""
                    document = WinSCPDocument(data: data)
                    showExporter = true
                } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
                busy = false
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

enum WinSCPBackgroundWork {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}
