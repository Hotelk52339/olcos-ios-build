import SwiftUI

// MARK: - ProtocolPageView
//
// One protocol on one server, pushed from its row on the server card. It
// answers three questions in order: does it work (the measured verdict, with
// Connect and Check), which rooms is it in (the main one and the extra rooms a
// whole-server connection joins at once; each can get a new room the app makes
// itself where the service allows it, or one typed in), and how is it set up
// (transport and service settings, start and stop, remove).
//
// Plain values and closures only: ServersView resolves them on every render —
// it owns the stores, the SSH lane and every dialog — and this file draws.
// That file has blown the type-checker's budget three times; new UI lives here.

/// One room of a protocol: the main one (number 1) or an extra one.
struct ProtocolRoom: Identifiable, Equatable {
    /// The container that sits in this room.
    let id: String
    let number: Int
    let room: String
    let isRunning: Bool
    var isMain: Bool { number == 1 }
}

struct ProtocolPageView: View {
    /// Service name ("Jitsi").
    let title: String
    /// Transport label ("DataChannel").
    let transport: String
    let health: HealthDisplay
    /// The live session runs through this protocol.
    let isLive: Bool
    /// Its server-side process is up.
    let isRunning: Bool
    /// Its container is gone (its settings file is still there): Start re-creates it.
    var isMissing = false
    /// The main room first, then the extra ones.
    let rooms: [ProtocolRoom]
    /// The app makes a new room by itself (Jitsi, SaluteJazz, Telemost signed in).
    let makesRooms: Bool
    /// Telemost with no Yandex sign-in stored yet.
    let needsYandexSignIn: Bool
    let canAddRoom: Bool
    /// Another operation holds the server: every action waits.
    let busy: Bool
    /// What the service and the transport are, one line each.
    let detailLines: [String]
    let onConnect: () -> Void
    let onVerify: () -> Void
    let onStartStop: () -> Void
    let onNewRoom: (ProtocolRoom) -> Void
    let onTypeRoom: (ProtocolRoom) -> Void
    let onAddRoom: () -> Void
    let onRemoveRoom: (ProtocolRoom) -> Void
    let onSettings: () -> Void
    /// The raw Yandex `Session_id` from the sign-in web view; the caller stores it.
    let onSignedIn: (String) -> Void
    /// Why the last check failed, in words; nil when it did not.
    var onShowReason: (() -> Void)? = nil
    /// Re-read this protocol's connection from the server; nil when it matches.
    var onRecover: (() -> Void)? = nil
    /// Remove the protocol from the server; nil for the server's first one.
    var onRemove: (() -> Void)? = nil

    @State private var showLogin = false

    var body: some View {
        Form {
            statusSection
            roomsSection
            setupSection
            removeSection
        }
        .signalFormChrome()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .sheet(isPresented: $showLogin) {
            YandexLoginView { session in
                showLogin = false
                onSignedIn(session)
            }
        }
    }

    // MARK: Does it work

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                ServerSignalStatus(tone: health.tone, title: health.title,
                                   subtitle: health.subtitle, isBusy: health.isChecking)
                if let state = stateLine {
                    Text(state)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
            if !isLive {
                actionRow(L10n.actionConnect.localized(), systemImage: "personalhotspot", action: onConnect)
            }
            actionRow(L10n.healthActionVerify.localized(), systemImage: "checkmark.shield", action: onVerify)
            if let onShowReason {
                actionRow(L10n.healthShowReasonAction.localized(), systemImage: "questionmark.circle",
                          action: onShowReason)
            }
        } header: {
            SignalSectionHeader(transport.isEmpty ? title : "\(title) · \(transport)")
        }
        .signalFormRows()
    }

    private var stateLine: String? {
        if isLive { return L10n.protocolLiveBadge.localized() }
        if !isRunning { return L10n.protocolStoppedNote.localized() }
        return nil
    }

    // MARK: Rooms

    private var roomsSection: some View {
        Section {
            ForEach(rooms) { room in
                roomRow(room)
            }
            if needsYandexSignIn {
                actionRow(L10n.telemostRoomSignInAction.localized(), systemImage: "person.badge.key") {
                    showLogin = true
                }
            } else if canAddRoom {
                actionRow(L10n.protocolAddRoom.localized(), systemImage: "plus.circle", action: onAddRoom)
            }
        } header: {
            SignalSectionHeader(L10n.protocolRoomsHeader.localized())
        } footer: {
            Text((makesRooms ? L10n.protocolRoomsFooterAuto : L10n.protocolRoomsFooterManual).localized())
        }
        .signalFormRows()
    }

    private func roomRow(_ room: ProtocolRoom) -> some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(room.isMain ? L10n.protocolMainRoom.localized()
                                 : L10n.protocolExtraRoom_fmt.formatted(room.number))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(room.room.isEmpty ? "—" : room.room)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !room.isRunning {
                    Text(L10n.protocolStoppedNote.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: Theme.Metrics.s2)
            Menu {
                if makesRooms {
                    Button { onNewRoom(room) } label: {
                        Label(L10n.protocolNewRoomAuto.localized(), systemImage: "sparkles")
                    }
                }
                Button { onTypeRoom(room) } label: {
                    Label(L10n.protocolTypeRoom.localized(), systemImage: "keyboard")
                }
                if !room.isMain, room.id == rooms.last?.id {
                    Button(role: .destructive) { onRemoveRoom(room) } label: {
                        Label(L10n.laneRemoveAction.localized(), systemImage: "minus.circle")
                    }
                }
            } label: {
                Text(L10n.protocolChangeRoom.localized())
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Signal.stroke)
                    .frame(minHeight: Theme.Metrics.controlHeight)
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            actionRow(L10n.protocolSettingsAction.localized(), systemImage: "slider.horizontal.3",
                      action: onSettings)
            actionRow(startStopTitle, systemImage: isRunning ? "stop.fill" : "play.fill",
                      action: onStartStop)
            if let onRecover {
                actionRow(L10n.actionRecoverConnection.localized(), systemImage: "arrow.counterclockwise.circle",
                          action: onRecover)
            }
        } header: {
            SignalSectionHeader(L10n.protocolSetupHeader.localized())
        } footer: {
            if !detailLines.isEmpty {
                Text(detailLines.joined(separator: "\n"))
            }
        }
        .signalFormRows()
    }

    private var startStopTitle: String {
        if isRunning { return L10n.protocolStopAction.localized() }
        if isMissing { return L10n.protocolRecreateAction.localized() }
        return L10n.protocolStartAction.localized()
    }

    @ViewBuilder
    private var removeSection: some View {
        if let onRemove {
            Section {
                Button(role: .destructive, action: onRemove) {
                    Label(L10n.removeProtocolAction.localized(), systemImage: "trash")
                        .font(Theme.Typography.body)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
            }
            .signalFormRows()
        }
    }

    // MARK: Row

    private func actionRow(_ title: String, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(minHeight: Theme.Metrics.controlHeight)
    }
}
