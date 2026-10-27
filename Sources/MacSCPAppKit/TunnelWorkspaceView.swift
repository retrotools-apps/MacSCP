import SwiftUI
import macSCPCore

struct TunnelWorkspaceView: View {
    let manager: TunnelManager
    let sessions: [StoredSession]
    let decider: HostKeyDecider
    var selection: Binding<TunnelWorkspaceSelection> = .constant(.all)
    var requestsNewTunnel: Binding<Bool> = .constant(false)
    @Environment(\.openURL) private var openURL
    @Environment(\.highContrast) private var highContrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeOnly = false
    @State private var editor: TunnelEditorItem?
    @State private var deletion: TunnelProfile?
    @State private var errorMessage: String?

    private var carriers: [StoredSession] { sessions.filter { $0.kind == .ssh } }
    private var scopedProfiles: [TunnelProfile] {
        TunnelCatalog.profiles(selection: selection.wrappedValue, profiles: manager.allProfiles, groups: manager.allGroups)
    }
    private var visibleProfiles: [TunnelProfile] {
        scopedProfiles.filter { !activeOnly || selection.wrappedValue != .all || TunnelPresentationState.isActive(manager.state(of: $0.id)) }
    }
    private var selectedGroupID: UUID? {
        switch selection.wrappedValue {
        case .group(let id): return id
        case .profile(let id): return manager.allProfiles.first { $0.id == id }?.groupID
        case .all, .ungrouped: return nil
        }
    }
    private var title: String {
        switch selection.wrappedValue {
        case .all: return L10n.string("workspace.tunnels", "Tunnels")
        case .ungrouped: return L10n.string("tunnels.group.ungrouped", "Ungrouped")
        case .group(let id): return manager.allGroups.first { $0.id == id }?.name ?? L10n.string("workspace.tunnels", "Tunnels")
        case .profile(let id): return manager.allProfiles.first { $0.id == id }?.name ?? L10n.string("workspace.tunnels", "Tunnels")
        }
    }
    private var startTitle: String {
        switch selection.wrappedValue {
        case .group: return L10n.string("tunnels.group.start", "Start group")
        case .profile: return L10n.string("tunnel.action.start", "Start")
        case .all, .ungrouped: return L10n.string("tunnels.startAll", "Start all")
        }
    }
    private var stopTitle: String {
        switch selection.wrappedValue {
        case .group: return L10n.string("tunnels.group.stop", "Stop group")
        case .profile: return L10n.string("tunnel.action.stop", "Stop")
        case .all, .ungrouped: return L10n.string("tunnels.stopAll", "Stop all")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if visibleProfiles.isEmpty {
                ContentUnavailableView {
                    Label { Text(activeOnly && !scopedProfiles.isEmpty ? L10n.string("tunnels.noActive", "No active tunnels") : L10n.string("tunnels.empty", "No tunnels yet")) } icon: { TunnelIcon(size: 40) }
                        .help(L10n.string("tunnels.empty", "No tunnels yet"))
                } description: {
                    if !activeOnly || scopedProfiles.isEmpty { Text(L10n.string("tunnels.empty.detail", "Create a mapping and choose the saved SSH connection that carries it.")) }
                }
                if carriers.isEmpty {
                    Text(L10n.string("tunnels.noCarriers", "Create an SCP session first to use its SSH connection."))
                        .foregroundStyle(.secondary).padding()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let hues = groupHues
                        ForEach(Array(visibleProfiles.enumerated()), id: \.element.id) { index, profile in
                            tunnelRow(profile)
                                .background {
                                    ZStack {
                                        if colorScheme == .light { DesignTokens.card }
                                        Color.primary.opacity(highContrast ? (index.isMultiple(of: 2) ? 0.04 : 0.10) : GroupTintStyle.tunnelRowOpacity(
                                            alternate: index.isMultiple(of: 2) == false,
                                            dark: colorScheme == .dark))
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    TunnelGroupAccent(hue: profile.groupID.flatMap { hues[$0] },
                                        customColor: manager.allGroups.first { $0.id == profile.groupID }?.color)
                                }
                            Divider().padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: requestsNewTunnel.wrappedValue) { _, requested in
            guard requested else { return }
            editor = .init(profile: nil)
            requestsNewTunnel.wrappedValue = false
        }
        .onChange(of: manager.allGroups.map(\.id)) { _, ids in
            if case .group(let id) = selection.wrappedValue, !ids.contains(id) { selection.wrappedValue = .ungrouped }
        }
        .onChange(of: manager.allProfiles.map(\.id)) { _, ids in
            if case .profile(let id) = selection.wrappedValue, !ids.contains(id) { selection.wrappedValue = .all }
        }
        .sheet(item: $editor) { item in
            TunnelWorkspaceEditor(
                profile: item.profile, sessions: carriers, manager: manager,
                onClose: { editor = nil }, initialGroupID: selectedGroupID)
        }
        .confirmationDialog(
            L10n.string("tunnels.delete.confirm", "Delete this tunnel? It will be stopped."),
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
        ) {
            Button(L10n.string("tunnel.action.delete", "Delete"), role: .destructive) {
                guard let profile = deletion else { return }
                Task {
                    do { try await manager.remove(profile) }
                    catch { errorMessage = error.localizedDescription }
                    deletion = nil
                }
            }
        }
        .alert(L10n.string("tunnels.error", "Tunnel could not be saved"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(L10n.string("common.ok", "OK")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(L10n.string("tunnels.subtitle", "Local, remote and SOCKS forwarding across your SSH connections."))
                    .font(.callout).foregroundStyle(.secondary)
                if selection.wrappedValue == .all {
                    Toggle(L10n.string("tunnels.activeOnly", "Active only"), isOn: $activeOnly)
                        .toggleStyle(.switch).controlSize(.mini).font(.caption)
                        .fixedSize().padding(.top, 6)
                }
            }
            Spacer(minLength: 4)
            Button {
                Task {
                    if case .group(let id) = selection.wrappedValue {
                        await manager.startGroup(id, decider: decider)
                    } else {
                        for profile in scopedProfiles where !isRunning(manager.state(of: profile.id)) {
                            await manager.start(profile, decider: decider)
                        }
                    }
                }
            } label: {
                Label(startTitle, systemImage: "play.fill")
            }
            .help(startTitle)
            .disabled(scopedProfiles.isEmpty)
            Button {
                Task {
                    if case .group(let id) = selection.wrappedValue { await manager.stopGroup(id) }
                    else if selection.wrappedValue == .all { await manager.stopAll() }
                    else { for profile in scopedProfiles { await manager.stop(profile) } }
                }
            } label: {
                Label(stopTitle, systemImage: "stop.fill")
            }
            .help(stopTitle)
            .disabled(!TunnelPresentationState.canStopAll(
                scopedProfiles.map { manager.state(of: $0.id) }))
        }
        .controlSize(.small)
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var groupHues: [UUID: Double] {
        SidebarGroupBands.hues(groups: manager.allGroups.map(SidebarGroupBands.Group.init))
    }

    private func tunnelRow(_ profile: TunnelProfile) -> some View {
        let state = manager.state(of: profile.id)
        let running = isRunning(state)
        let carrier = sessions.first { $0.id == profile.sessionID }
        return HStack(alignment: .center, spacing: 12) {
            TunnelServiceIcon(appearance: profile.appearance, size: 20)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(stateColor(state)).frame(width: 6, height: 6)
                        .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
                        .offset(x: 3, y: 3)
                }
                .frame(width: 28)
                .help(TunnelProfilesSheet.stateTooltip(state))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    tunnelIdentity(profile).fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        tunnelSSHRoute(profile, carrier: carrier)
                        tunnelSecurity(profile)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 240, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    tunnelIdentity(profile)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            tunnelSSHRoute(profile, carrier: carrier)
                            tunnelSecurity(profile)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            tunnelSSHRoute(profile, carrier: carrier)
                            tunnelSecurity(profile)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(TunnelProfilesSheet.stateLabel(state))
                    .font(.caption).foregroundStyle(stateColor(state))
                    .multilineTextAlignment(.trailing).frame(maxWidth: 210, alignment: .trailing)
                    .help(TunnelProfilesSheet.stateTooltip(state))
                HStack(spacing: 8) {
                    if TunnelPresentationState.canDismiss(state) {
                        Button(L10n.string("tunnel.action.dismiss", "Dismiss")) {
                            Task { await manager.stop(profile) }
                        }
                        .help(L10n.string("tunnel.action.dismissHelp", "Clear the last error and return this tunnel to Stopped without restarting it."))
                    }
                    if case .active = state, let url = TunnelEndpoints.browserURL(for: profile) {
                        Button { openURL(url) } label: {
                            Label(L10n.string("tunnels.open", "Open in browser"), systemImage: "safari")
                                .labelStyle(.iconOnly)
                        }
                        .help(L10n.string("tunnels.open", "Open in browser"))
                    }
                    Button(running ? L10n.string("tunnel.action.stop", "Stop") : L10n.string("tunnel.action.start", "Start")) {
                        toggleTunnel(profile)
                    }
                    .frame(minWidth: 48)
                    Button { editor = .init(profile: profile) } label: {
                        Label(L10n.string("tunnel.action.edit", "Edit"), systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .help(L10n.string("tunnel.action.edit", "Edit"))
                    Menu {
                        TunnelPortReleaseButton(profile: profile, manager: manager, decider: decider)
                        Button(L10n.string("tunnel.action.delete", "Delete"), role: .destructive) { deletion = profile }
                    } label: {
                        Label(L10n.string("tunnels.more", "More actions"), systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).frame(width: 20)
                    .menuIndicator(.hidden)
                    .help(L10n.string("tunnels.more", "More actions"))
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleTunnel(profile) }
        .modifier(TunnelProfileActions(profile: profile, sessions: sessions, manager: manager, decider: decider))
    }

    private func toggleTunnel(_ profile: TunnelProfile) {
        Task {
            switch TunnelPresentationState.toggleAction(for: manager.state(of: profile.id)) {
            case .start: await manager.start(profile, decider: decider)
            case .stop: await manager.stop(profile)
            }
        }
    }

    private func tunnelIdentity(_ profile: TunnelProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(profile.name).font(.headline).lineLimit(1).help(profile.name)
                Text((profile.service ?? .tcp).rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(TunnelProfilesSheet.kindLabel(profile.kind))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.routeText(profile))
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(Self.routeText(profile))
        }
    }

    private func tunnelSSHRoute(_ profile: TunnelProfile, carrier: StoredSession?) -> some View {
        HStack(spacing: 8) {
            Label(carrier?.name ?? L10n.string("tunnels.missingCarrier", "Missing connection"), systemImage: "server.rack")
                .help(carrier?.name ?? L10n.string("tunnels.missingCarrier", "Missing connection"))
            if let hop = profile.jumpSessionID ?? carrier?.jump?.sessionID {
                Label(sessions.first { $0.id == hop }?.name ?? L10n.string("tunnels.missingCarrier", "Missing connection"),
                      systemImage: "arrow.triangle.branch")
                    .help(sessions.first { $0.id == hop }?.name ?? L10n.string("tunnels.missingCarrier", "Missing connection"))
            } else if let jump = carrier?.jump {
                Label(jump.host, systemImage: "arrow.triangle.branch")
                    .help(jump.host)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func tunnelSecurity(_ profile: TunnelProfile) -> some View {
        HStack(spacing: 8) {
            if let tls = Self.tlsTransport(profile, sessions: sessions) {
                Label(tls.verifyCertificate ? "TLS" : L10n.string("tunnels.tls.unverified", "TLS · certificate not verified"),
                      systemImage: tls.verifyCertificate ? "lock.shield" : "exclamationmark.shield")
                    .foregroundStyle(tls.verifyCertificate ? Color.secondary : .orange)
                    .help(L10n.string("connection.tls.verify", "Verify TLS certificate and server name (recommended)"))
            }
            if profile.autoStart != .off {
                Text(TunnelProfilesSheet.autoStartLabel(profile.autoStart))
            }
            if profile.reconnects {
                Image(systemName: "arrow.clockwise")
                    .help(L10n.string("tunnels.reconnect", "Reconnect after interruption"))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func isRunning(_ state: TunnelState) -> Bool {
        switch state {
        case .connecting, .reconnecting, .active: return true
        case .stopped, .failed, .needsConfirmation: return false
        }
    }

    static func routeText(_ profile: TunnelProfile) -> String {
        func endpoint(_ host: String, _ port: Int) -> String {
            "\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host):\(port)"
        }
        switch profile.kind {
        case .local(let bind, let local, let host, let remote):
            return "\(endpoint(bind, local)) → \(endpoint(host, remote))"
        case .remote(let bind, let remote, let host, let local):
            return "\(endpoint(bind, remote)) → \(endpoint(host, local))"
        case .dynamic(let bind, let port): return "\(endpoint(bind, port)) → SOCKS5"
        }
    }

    static func tlsTransport(_ profile: TunnelProfile, sessions: [StoredSession]) -> SSHTLSTunnelConfig? {
        guard let carrier = sessions.first(where: { $0.id == profile.sessionID }) else { return nil }
        if let hop = profile.jumpSessionID ?? carrier.jump?.sessionID {
            return sessions.first(where: { $0.id == hop })?.ssh?.tlsTunnel
        }
        return carrier.jump?.tlsTunnel ?? carrier.ssh?.tlsTunnel
    }

    private func stateColor(_ state: TunnelState) -> Color {
        switch state {
        case .active: return state.isDegraded ? .orange : .green
        case .failed: return .red
        case .connecting, .reconnecting, .needsConfirmation: return .orange
        case .stopped: return .secondary
        }
    }
}

private struct TunnelEditorItem: Identifiable {
    let id = UUID()
    let profile: TunnelProfile?
}

/// Configuration editor: only short-lived local bind probes run here. No SSH
/// connection or host-key prompt starts until the user starts a saved mapping.
struct TunnelWorkspaceEditor: View {
    let profile: TunnelProfile?
    let sessions: [StoredSession]
    let manager: TunnelManager
    let onClose: () -> Void
    var isDuplicate = false
    var initialGroupID: UUID? = nil
    @State private var draft = TunnelProfileDraft()
    @State private var carrierID: UUID?
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var suggestedPort: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(profile == nil ? L10n.string("tunnels.new", "New tunnel…") : L10n.string("tunnels.edit", "Edit tunnel"))
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                TextField(L10n.string("tunnel.field.name", "Name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Picker(L10n.string("tunnels.direction", "Direction"), selection: $draft.kindTag) {
                    Text(L10n.string("tunnels.local", "Local → remote")).tag(TunnelProfileDraft.KindTag.local)
                    Text(L10n.string("tunnels.remote", "Remote → local")).tag(TunnelProfileDraft.KindTag.remote)
                    Text(L10n.string("tunnels.socks", "SOCKS5 proxy")).tag(TunnelProfileDraft.KindTag.dynamic)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
            }
            .disabled(saving)
            TunnelRouteFlow(draft: $draft, carrierID: Binding(
                get: { carrierID },
                set: { carrierID = $0; draft.jumpSessionID = nil }), sessions: sessions)
                .disabled(saving)
            TunnelAppearancePicker(appearance: $draft.appearance)
                .disabled(saving)
            HStack(spacing: 24) {
                Picker(L10n.string("tunnels.autostart", "Automatic start"), selection: $draft.autoStart) {
                    ForEach(TunnelProfile.AutoStart.allCases, id: \.self) {
                        Text(TunnelProfilesSheet.autoStartLabel($0)).tag($0)
                    }
                }
                .frame(width: 260)
                Toggle(L10n.string("tunnels.reconnect", "Reconnect after interruption"), isOn: $draft.reconnects)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
            .disabled(saving)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            Text(L10n.string("tunnels.saveStops", "Saving an edited tunnel stops it. Start it again to apply the changes."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(L10n.string("common.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(saving || carrierID == nil)
            }
        }
        .padding(24).frame(width: 900, height: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let profile {
                draft = TunnelProfileDraft(profile: profile); carrierID = profile.sessionID
                if isDuplicate {
                    draft.name = String(format: L10n.string("tunnels.copy %@", "%@ copy"), profile.name)
                    draft.autoStart = .off
                    if draft.kindTag != .remote { draft.listenPort = "" }
                }
            }
            else { carrierID = nil; draft.groupID = initialGroupID }
        }
        .task(id: "\(draft.kindTag.rawValue)|\(draft.bind)") {
            guard profile == nil || isDuplicate, draft.kindTag != .remote,
                  draft.listenPort.isEmpty || draft.listenPort == suggestedPort else { return }
            let original = draft.listenPort
            let port = await TunnelPortSuggestion.suggest(bind: draft.bind, profiles: manager.allProfiles)
            guard !Task.isCancelled, draft.listenPort == original, let port else { return }
            suggestedPort = String(port)
            draft.listenPort = String(port)
        }
    }

    private func save() {
        guard let carrierID else { return }
        switch draft.profile(id: isDuplicate ? UUID() : (profile?.id ?? UUID()), sessionID: carrierID) {
        case .failure(let invalid): errorMessage = TunnelProfilesSheet.message(for: invalid)
        case .success(var value):
            if draft.kindTag != .local { value.service = nil }
            do { try TunnelSSHConfiguration.validateRoute(profile: value, sessions: sessions) }
            catch TunnelSSHConfiguration.ResolutionError.targetTLSBehindJump {
                errorMessage = L10n.string("tunnels.nestedTLS", "TLS is supported on the first SSH hop, not inside an additional jump. Choose the TLS bastion as the jump host.")
                return
            } catch {
                errorMessage = L10n.string("tunnels.invalidRoute", "Choose an existing SSH connection and a valid jump host. The jump cannot itself use another jump.")
                return
            }
            guard value.jumpSessionID != carrierID else {
                errorMessage = L10n.string("tunnels.jump.self", "The SSH connection cannot be its own jump host.")
                return
            }
            saving = true
            Task {
                do { try await manager.save(value); onClose() }
                catch { errorMessage = TunnelCatalog.groupError(error); saving = false }
            }
        }
    }
}

/// A route describes the saved SSH endpoint and the hop used to reach it.
/// It is metadata only: no credential lookup and no network operation.
struct TunnelRoutePresentation: Equatable {
    let endpointName: String?
    let gatewayName: String?
    let tls: SSHTLSTunnelConfig?
    let overridesSavedRoute: Bool

    init(carrierID: UUID?, overrideID: UUID?, sessions: [StoredSession]) {
        let carrier = sessions.first { $0.id == carrierID }
        endpointName = carrier?.name
        overridesSavedRoute = overrideID != nil
        if let hopID = overrideID ?? carrier?.jump?.sessionID {
            let gateway = sessions.first { $0.id == hopID }
            gatewayName = gateway?.name ?? L10n.string("tunnels.missingCarrier", "Missing connection")
            tls = gateway?.ssh?.tlsTunnel
        } else {
            gatewayName = carrier?.jump?.host
            tls = carrier?.jump?.tlsTunnel ?? carrier?.ssh?.tlsTunnel
        }
    }
}

/// One visual flow, not two independent SSH configuration selectors. The
/// selected session supplies authentication and its existing jump/TLS route.
struct TunnelRouteFlow: View {
    @Binding var draft: TunnelProfileDraft
    @Binding var carrierID: UUID?
    let sessions: [StoredSession]

    private var route: TunnelRoutePresentation {
        .init(carrierID: carrierID, overrideID: draft.jumpSessionID, sessions: sessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    heading(draft.kindTag == .remote
                            ? L10n.string("tunnels.flow.remoteListener", "Listen on the SSH server")
                            : L10n.string("tunnels.flow.localListener", "Listen on this Mac"), symbol: TunnelSymbols.tunnel)
                    field(L10n.string("tunnels.bind", "Listen address"), text: $draft.bind)
                    field(L10n.string("tunnels.listen", "Listen port"), text: $draft.listenPort)
                        .help(draft.kindTag == .remote ? L10n.string("tunnels.listen", "Listen port")
                              : L10n.string("tunnels.portSuggestionHelp", "A free local port is proposed from 65534 downwards. You can enter another port."))
                }.frame(width: 195)
                flowArrow
                VStack(alignment: .leading, spacing: 12) {
                    heading(L10n.string("tunnels.flow.route", "SSH route"), symbol: "server.rack")
                    if let gateway = route.gatewayName {
                        Text(L10n.string("tunnels.flow.gateway", "Through the bastion"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(gateway).font(.callout.weight(.medium)).lineLimit(1).help(gateway)
                        Label(L10n.string("tunnels.flow.then", "Then connect to"), systemImage: "arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(L10n.string("tunnels.flow.then", "Then connect to"))
                    } else {
                        Text(L10n.string("tunnels.flow.direct", "Direct SSH connection"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(L10n.string("tunnels.flow.endpoint", "SSH server"), selection: $carrierID) {
                        Text(L10n.string("tunnels.choose", "Choose a connection")).tag(UUID?.none)
                        ForEach(sessions) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().accessibilityLabel(L10n.string("tunnels.flow.endpoint", "SSH server"))
                    if let tls = route.tls {
                        Text(tls.verifyCertificate ? L10n.string("tunnels.flow.tls", "TLS gateway · certificate verification enabled")
                             : L10n.string("tunnels.tls.unverified", "TLS · certificate not verified"))
                            .font(.caption).foregroundStyle(tls.verifyCertificate ? Color.secondary : .orange)
                    }
                    if route.overridesSavedRoute {
                        Text(L10n.string("tunnels.flow.override", "This tunnel retains a custom saved route."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.string("tunnels.flow.reset", "Use the session’s route")) { draft.jumpSessionID = nil }
                            .controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                flowArrow
                VStack(alignment: .leading, spacing: 12) {
                    heading(L10n.string("tunnels.flow.destination", "Reach the destination"), symbol: "scope")
                    if draft.namesATarget {
                        field(L10n.string("tunnels.destination", "Destination host"), text: $draft.targetHost)
                        field(L10n.string("tunnels.destinationPort", "Destination port"), text: $draft.targetPort)
                    } else {
                        Text(L10n.string("tunnel.target.negotiated", "Chosen per connection"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if draft.kindTag == .local {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.string("tunnels.protocol", "Application protocol"))
                                .font(.caption).foregroundStyle(.secondary)
                            Picker(L10n.string("tunnels.protocol", "Application protocol"), selection: Binding(
                                get: { draft.service ?? .tcp }, set: { draft.service = $0 })
                            ) {
                                ForEach(TunnelProfile.Service.allCases, id: \.self) { service in
                                    Text(service.rawValue.uppercased()).tag(service)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }.frame(width: 195)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 17, weight: .medium)).foregroundStyle(.tertiary)
            .padding(.top, 82)
            .help(L10n.string("tunnels.flow.traffic", "Traffic flow"))
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label { Text(title) } icon: {
            if symbol == TunnelSymbols.tunnel { TunnelIcon() }
            else { Image(systemName: symbol).help(title) }
        }
        .font(.callout.weight(.semibold)).help(title)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).labelsHidden()
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        }
    }
}

struct TunnelPortConflictError: LocalizedError {
    let existing: String
    var errorDescription: String? {
        String(format: L10n.string("tunnels.portConflict %@", "The listen address and port overlap with “%@”. Choose another port or address."), existing)
    }
}
