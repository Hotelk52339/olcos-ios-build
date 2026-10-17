import SwiftUI

/// Step 4 — one card per selected carrier.
/// Telemost: sign in to Yandex if needed, then the room is created here and
/// its ID travels into `InstallOptions.roomID`. SaluteJazz: created here too,
/// with no account. VK Calls: a call link made in the VK app. Jitsi: instance
/// + room name. WB Stream: room ID + optional account token.
struct AddServerRoomStep: View {
    @ObservedObject var flow: AddServerFlowController
    @ObservedObject var yandexStore: YandexSessionStore
    @State private var showYandexLogin = false
    @State private var showVKLogin = false
    @State private var showWBLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowRoomLead)
            ForEach(flow.plan.selected, id: \.self) { carrier in
                switch carrier {
                case "telemost":   telemostCard
                case "vkcalls":    vkCard
                case "salutejazz": saluteCard
                case "jitsi":      jitsiCard
                case "wbstream":   wbstreamCard
                default:           EmptyView()
                }
            }
        }
        .sheet(isPresented: $showYandexLogin) {
            YandexLoginView { session in
                showYandexLogin = false
                flow.yandexSignedIn(session)
            }
        }
        .sheet(isPresented: $showVKLogin) {
            VKLoginView { session in
                showVKLogin = false
                flow.vkSignedIn(session)
            }
        }
        .sheet(isPresented: $showWBLogin) {
            WBLoginView { token in
                showWBLogin = false
                flow.wbSignedIn(token)
            }
        }
    }

    private func roomError(_ carrier: String) -> String? {
        guard flow.showRoomErrors,
              let error = flow.roomErrors.first(where: { $0.carrier == carrier }) else { return nil }
        let label = CarrierTransportMatrix.carrierLabel(carrier)
        switch error {
        case .missing: return L10n.addFlowRoomMissing_fmt.formatted(label)
        case .invalid: return L10n.addFlowRoomInvalid_fmt.formatted(label)
        }
    }

    private func header(_ carrier: String) -> some View {
        HStack(spacing: Theme.Metrics.s2) {
            Text(CarrierTransportMatrix.carrierLabel(carrier))
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            AddServerBadge(text: CarrierTransportMatrix.transportLabel(flow.plan.transport(for: carrier)),
                           tone: .unknown)
            Spacer(minLength: 0)
        }
    }

    // MARK: Telemost — auto room

    private var telemostCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("telemost")
                switch flow.telemost {
                case .needsSignIn:
                    ServerSignalStatus(tone: .warn,
                                       title: L10n.telemostRoomSignInAction.localized(),
                                       subtitle: L10n.addFlowYandexSignInBody.localized())
                    OlcButton(L10n.telemostRoomSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                              role: .primary, fillWidth: true) { showYandexLogin = true }
                case .creating:
                    ServerSignalStatus(tone: .progress,
                                       title: L10n.addFlowTelemostCreating.localized(),
                                       subtitle: L10n.telemostRoomKeychainNote.localized(),
                                       isBusy: true)
                case .created(let room):
                    ServerSignalStatus(tone: .ok,
                                       title: L10n.addFlowTelemostCreated.localized(),
                                       subtitle: L10n.addFlowTelemostCreatedBody.localized())
                    AddServerFactRow(label: L10n.roomIDLabel.localized(), value: room.id, mono: true)
                    HStack(spacing: Theme.Metrics.s3) {
                        OlcButton(L10n.telemostNewRoomAction.localized(), systemImage: "arrow.clockwise",
                                  role: .secondary, compact: true) { flow.createTelemostRoom() }
                        OlcButton(L10n.telemostRoomOtherAccountAction.localized(), systemImage: "person.2",
                                  role: .ghost, compact: true) { flow.switchYandexAccount() }
                    }
                case .failed(let message, let needsSignIn):
                    ServerSignalStatus(tone: .error,
                                       title: L10n.addFlowTelemostFailed.localized(),
                                       subtitle: message)
                    if needsSignIn {
                        OlcButton(L10n.telemostRoomSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                                  role: .primary, fillWidth: true) { showYandexLogin = true }
                    } else {
                        OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                                  role: .secondary, fillWidth: true) { flow.createTelemostRoom() }
                    }
                }
                if let e = roomError("telemost"), flow.telemost != .creating {
                    AddServerInlineError(message: e)
                }
            }
        }
    }

    // MARK: VK Calls — made by the app, or a link from the VK app

    @ViewBuilder
    private var vkStatus: some View {
        switch flow.vk {
        case .needsSignIn:
            ServerSignalStatus(tone: .warn,
                               title: L10n.vkSignInAction.localized(),
                               subtitle: L10n.addFlowVKBody.localized())
            OlcButton(L10n.vkSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                      role: .primary, fillWidth: true) { showVKLogin = true }
        case .creating:
            ServerSignalStatus(tone: .progress,
                               title: L10n.addFlowVKCreating.localized(),
                               subtitle: L10n.telemostRoomKeychainNote.localized(),
                               isBusy: true)
        case .created(let link):
            ServerSignalStatus(tone: .ok,
                               title: L10n.addFlowVKCreated.localized(),
                               subtitle: L10n.addFlowVKBody.localized())
            AddServerFactRow(label: L10n.vkCallLinkField.localized(), value: link, mono: true)
            HStack(spacing: Theme.Metrics.s3) {
                OlcButton(L10n.roomAnotherAction.localized(), systemImage: "arrow.clockwise",
                          role: .secondary, compact: true) { flow.createVKCall() }
                OlcButton(L10n.telemostRoomOtherAccountAction.localized(), systemImage: "person.2",
                          role: .ghost, compact: true) { flow.switchVKAccount() }
            }
        case .failed(let message, let needsSignIn):
            ServerSignalStatus(tone: .error,
                               title: L10n.roomCreateFailed.localized(),
                               subtitle: message)
            if needsSignIn {
                OlcButton(L10n.vkSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                          role: .primary, fillWidth: true) { showVKLogin = true }
            } else {
                OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                          role: .secondary, fillWidth: true) { flow.createVKCall() }
            }
        }
    }

    private var vkCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("vkcalls")
                vkStatus
                // The manual path is never closed: a link from the VK app works
                // with or without a linked account.
                HStack(spacing: Theme.Metrics.s3) {
                    OlcButton(L10n.pasteAction.localized(), systemImage: "doc.on.clipboard",
                              role: .ghost, compact: true) {
                        flow.rooms.vkLink = UIPasteboard.general.string ?? ""
                    }
                }
                AddServerTextField(label: L10n.vkCallLinkField.localized(),
                                   placeholder: CarrierRoomInput.placeholder(carrier: "vkcalls"),
                                   text: $flow.rooms.vkLink, mono: true)
                    .keyboardType(.URL)
                if let link = VKCallLink.normalized(flow.rooms.vkLink), link != flow.rooms.vkLink {
                    // What the server will get, when the paste carried more.
                    Label(link, systemImage: "checkmark.circle")
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(L10n.vkCallLinkRecognized.localized() + " " + link)
                }
                if let e = roomError("vkcalls"), flow.vk != .creating {
                    AddServerInlineError(message: e)
                }
            }
        }
    }

    // MARK: SaluteJazz — created here, no account

    private var saluteCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("salutejazz")
                switch flow.salute {
                case .idle, .creating:
                    ServerSignalStatus(tone: .progress,
                                       title: L10n.addFlowSaluteCreating.localized(),
                                       subtitle: L10n.addFlowSaluteBody.localized(),
                                       isBusy: flow.salute == .creating)
                case .created:
                    ServerSignalStatus(tone: .ok,
                                       title: L10n.addFlowSaluteCreated.localized(),
                                       subtitle: L10n.addFlowSaluteBody.localized())
                    OlcButton(L10n.saluteAnotherRoomAction.localized(), systemImage: "arrow.clockwise",
                              role: .secondary, compact: true) { flow.createSaluteRoom() }
                case .failed(let message):
                    ServerSignalStatus(tone: .error,
                                       title: L10n.addFlowSaluteFailed.localized(),
                                       subtitle: message)
                    OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                              role: .secondary, compact: true) { flow.createSaluteRoom() }
                }
                AddServerTextField(label: L10n.fieldRoomID.localized(),
                                   placeholder: CarrierRoomInput.placeholder(carrier: "salutejazz"),
                                   text: $flow.rooms.saluteRoom, mono: true)
                if let e = roomError("salutejazz"), flow.salute != .creating {
                    AddServerInlineError(message: e)
                }
            }
        }
    }

    // MARK: Jitsi — instance + room name

    /// What the VPS probe found: the instance it filled in, or why it could
    /// not pick one. Silent once the user has chosen for themselves.
    @ViewBuilder
    private var jitsiStatus: some View {
        switch flow.jitsi {
        case .idle, .custom:
            EmptyView()
        case .checking:
            ServerSignalStatus(tone: .progress,
                               title: L10n.addFlowJitsiChecking.localized(),
                               subtitle: L10n.addFlowJitsiCheckingBody.localized(),
                               isBusy: true)
        case .picked(let host):
            ServerSignalStatus(tone: .ok,
                               title: L10n.addFlowJitsiPicked_fmt.formatted(host),
                               subtitle: L10n.addFlowJitsiPickedBody.localized())
        case .noneWorking:
            ServerSignalStatus(tone: .warn,
                               title: L10n.addFlowJitsiNoneWorking.localized(),
                               subtitle: L10n.addFlowJitsiNoneWorkingBody.localized())
            jitsiRecheckButton
        case .failed(let message):
            ServerSignalStatus(tone: .error,
                               title: L10n.addFlowJitsiCheckFailed.localized(),
                               subtitle: message)
            jitsiRecheckButton
        }
    }

    private var jitsiRecheckButton: some View {
        OlcButton(L10n.addFlowJitsiRecheck.localized(), systemImage: "arrow.clockwise",
                  role: .secondary, compact: true) { flow.probeJitsi() }
    }

    private var jitsiCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("jitsi")
                jitsiStatus
                OlcSectionHeader(L10n.addFlowJitsiInstance.localized())
                Menu {
                    ForEach(CarrierEndpoints.jitsiInstances, id: \.self) { host in
                        Button {
                            flow.chooseJitsi(CarrierEndpoints.jitsiBaseURL(forInstance: host))
                        } label: {
                            // The probe's verdict for this host, in the menu itself.
                            if flow.workingJitsiHosts.contains(host) {
                                Label(host, systemImage: "checkmark.circle")
                            } else {
                                Text(host)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(CarrierEndpoints.host(fromRoomID: flow.rooms.jitsiBaseURL) ?? flow.rooms.jitsiBaseURL)
                            .font(Theme.Typography.metricValue)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Metrics.s2)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .frame(minHeight: Theme.Metrics.controlHeight)
                    .padding(.horizontal, Theme.Metrics.s3)
                    .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                }
                AddServerTextField(label: L10n.addFlowJitsiCustom.localized(),
                                   placeholder: L10n.fieldJitsiURL.localized(),
                                   text: Binding(get: { flow.rooms.jitsiBaseURL },
                                                 set: { flow.chooseJitsi($0) }),
                                   mono: true)
                    .keyboardType(.URL)
                Text(L10n.addFlowJitsiInstanceNote.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AddServerTextField(label: L10n.addFlowJitsiRoomName.localized(),
                                   placeholder: "olc-room",
                                   text: $flow.rooms.jitsiRoomName, mono: true)
                Text(L10n.addFlowJitsiRoomHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let e = roomError("jitsi") { AddServerInlineError(message: e) }
            }
        }
    }

    // MARK: WB Stream — made by the app, or room id + token by hand

    /// While WB Stream is closed to regular accounts there is nothing to sign in
    /// to and no room to make, so the card says so instead of offering either.
    @ViewBuilder
    private var wbstreamStatus: some View {
        if CarrierAvailability.wbStreamOpen {
            wbstreamAccountStatus
        } else {
            ServerSignalStatus(tone: .warn,
                               title: L10n.wbStreamClosedTitle.localized(),
                               subtitle: L10n.addFlowWBBody.localized())
        }
    }

    @ViewBuilder
    private var wbstreamAccountStatus: some View {
        switch flow.wb {
        case .needsSignIn:
            ServerSignalStatus(tone: .warn,
                               title: L10n.wbSignInAction.localized(),
                               subtitle: L10n.addFlowWBBody.localized())
            OlcButton(L10n.wbSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                      role: .primary, fillWidth: true) { showWBLogin = true }
        case .creating:
            ServerSignalStatus(tone: .progress,
                               title: L10n.addFlowWBCreating.localized(),
                               subtitle: L10n.telemostRoomKeychainNote.localized(),
                               isBusy: true)
        case .created(let id):
            ServerSignalStatus(tone: .ok,
                               title: L10n.addFlowWBCreated.localized(),
                               subtitle: L10n.addFlowWBBody.localized())
            AddServerFactRow(label: L10n.roomIDLabel.localized(), value: id, mono: true)
            HStack(spacing: Theme.Metrics.s3) {
                OlcButton(L10n.roomAnotherAction.localized(), systemImage: "arrow.clockwise",
                          role: .secondary, compact: true) { flow.createWBRoom() }
                OlcButton(L10n.telemostRoomOtherAccountAction.localized(), systemImage: "person.2",
                          role: .ghost, compact: true) { flow.switchWBAccount() }
            }
        case .failed(let message, let needsSignIn):
            ServerSignalStatus(tone: .error,
                               title: L10n.roomCreateFailed.localized(),
                               subtitle: message)
            if needsSignIn {
                OlcButton(L10n.wbSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                          role: .primary, fillWidth: true) { showWBLogin = true }
            } else {
                OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                          role: .secondary, fillWidth: true) { flow.createWBRoom() }
            }
        }
    }

    private var wbstreamCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("wbstream")
                wbstreamStatus
                // The manual path stays: someone may still hold a room and a
                // token that WB accepts.
                AddServerTextField(label: L10n.fieldRoomID.localized(),
                                   placeholder: "1234567890",
                                   text: $flow.rooms.wbRoomID, mono: true)
                // The notice above already says what this hint would.
                if CarrierAvailability.wbStreamOpen {
                    Text(L10n.roomIDWbstreamHint.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let last = RoomMemory.lastRoom(forCarrier: "wbstream"), flow.rooms.wbRoomID.isEmpty {
                    OlcButton(L10n.roomIDLastUsed_fmt.formatted(last), systemImage: "clock.arrow.circlepath",
                              role: .ghost, compact: true) { flow.rooms.wbRoomID = last }
                }
                FormField(label: L10n.wbTokenFieldLabel.localized(),
                          placeholder: L10n.wbTokenPlaceholder.localized(),
                          text: $flow.rooms.wbToken, secure: true, mono: true,
                          helper: L10n.wbTokenFooter.localized())
                if let e = roomError("wbstream"), flow.wb != .creating {
                    AddServerInlineError(message: e)
                }
            }
        }
    }
}

/// Plain labelled text field in the wizard's field style.
struct AddServerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(placeholder, text: $text)
                .font(mono ? Theme.Typography.metricValue : Theme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: Theme.Metrics.chipHeight)
                .padding(.horizontal, Theme.Metrics.s3)
                .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                    .stroke(Theme.Palette.fillBorder, lineWidth: 1))
        }
    }
}
