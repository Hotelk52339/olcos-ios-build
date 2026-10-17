import SwiftUI

// MARK: - AddRoomSheet
//
// "Speed up: add a room" for one server: every call service on one sheet, each
// with how many rooms the server already sits in and what one more needs. A
// connection to the whole server joins every room at once, so each room adds
// its own speed. Services that need nothing get the room at once (Jitsi,
// SaluteJazz, and Telemost / VK Calls / WB Stream once their account is linked);
// Telemost and VK Calls ask for their sign-in right here when there is none;
// VK Calls without a sign-in asks for a call link. WB Stream is listed but
// closed to regular accounts (CarrierAvailability), so its row says so and
// cannot be tapped; were it open, it would go to the full form (it needs an
// account token). Every manual path stays open.

struct AddRoomChoice: Identifiable, Equatable {
    enum Need: Equatable {
        /// The app or the server makes the room: Jitsi, SaluteJazz, Telemost
        /// with a Yandex sign-in, VK Calls with a VK sign-in, WB Stream with a
        /// WB Stream sign-in.
        case nothing
        /// Telemost with no Yandex sign-in stored.
        case yandexSignIn
        /// VK Calls with no VK sign-in stored: a call link the user creates in
        /// the VK app, or a VK sign-in and the app makes the call.
        case callLink
        /// WB Stream with no account token: the full form asks for it.
        case accountForm
        /// WB Stream while it is closed to regular accounts: neither a sign-in
        /// nor an automatic room is offered, whatever the app holds.
        case unavailable
    }

    let carrier: String
    /// Rooms of this service on the server now; 0 when it is not there yet.
    let rooms: Int
    let need: Need

    var id: String { carrier }
    var isFull: Bool { rooms >= CarrierTransportMatrix.maxRooms }

    /// The order the sheet lists the services in: the ones that need nothing first.
    static let order = ["jitsi", "salutejazz", "telemost", "vkcalls", "wbstream"]

    /// PURE. One choice per call service, from the rooms the server holds and
    /// the accounts the app holds.
    static func make(rooms: [String: Int], yandexSignedIn: Bool,
                     vkSignedIn: Bool, wbSignedIn: Bool,
                     wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> [AddRoomChoice] {
        order.map { carrier in
            let need: Need
            switch carrier {
            case "telemost": need = yandexSignedIn ? .nothing : .yandexSignIn
            case "vkcalls":  need = vkSignedIn ? .nothing : .callLink
            case "wbstream":
                if !wbStreamOpen { need = .unavailable }
                else { need = wbSignedIn ? .nothing : .accountForm }
            default:         need = .nothing
            }
            return AddRoomChoice(carrier: carrier, rooms: rooms[carrier] ?? 0, need: need)
        }
    }
}

struct AddRoomSheet: View {
    let serverName: String
    let choices: [AddRoomChoice]
    /// A room was asked for; `link` is the VK call link when one was needed.
    /// The sheet closes itself first, and the server page shows the progress.
    let onAdd: (AddRoomChoice, _ link: String?) -> Void
    /// The Yandex sign-in finished with this session cookie.
    let onYandexSession: (String) -> Void
    /// The VK sign-in finished with this session cookie.
    let onVKSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var signInFor: AddRoomChoice?
    /// Signed in: the room is added once the sign-in sheet has gone.
    @State private var afterSignIn: AddRoomChoice?
    @State private var linkFor: AddRoomChoice?
    @State private var linkText = ""
    /// The VK sign-in sheet, opened from the paste-link alert's own button; the
    /// choice it was opened for.
    @State private var vkSignInFor: AddRoomChoice?
    @State private var showVKLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.addRoomLead.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .signalFormRows()
                Section {
                    ForEach(choices) { choice in
                        AddRoomRow(choice: choice) { tap(choice) }
                    }
                } footer: {
                    Text(L10n.addRoomLimit_fmt.formatted(CarrierTransportMatrix.maxRooms))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .signalFormRows()
            }
            .signalFormChrome()
            .navigationTitle(L10n.addRoomTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel.localized()) { dismiss() }
                }
            }
            .sheet(item: $signInFor, onDismiss: {
                guard let choice = afterSignIn else { return }
                afterSignIn = nil
                add(choice, link: nil)
            }) { choice in
                YandexLoginView { session in
                    onYandexSession(session)
                    afterSignIn = choice
                }
            }
            .sheet(isPresented: $showVKLogin, onDismiss: {
                vkSignInFor = nil
                // Only a sign-in that actually produced a session adds the
                // room; a cancelled sheet leaves `afterSignIn` nil.
                guard let choice = afterSignIn else { return }
                afterSignIn = nil
                // The sign-in sheet has dismissed ITSELF a moment ago;
                // dismissing this one inside that animation makes iOS drop
                // the second dismissal. The same deferral ServersView uses
                // after a sheet closes (~650 ms).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    add(choice, link: nil)
                }
            }) {
                VKLoginView { session in
                    onVKSession(session)
                    afterSignIn = vkSignInFor
                }
            }
            .alert(L10n.addRoomVKTitle.localized(),
                   isPresented: Binding(get: { linkFor != nil }, set: { if !$0 { linkFor = nil } }),
                   presenting: linkFor) { choice in
                TextField(CarrierRoomInput.placeholder(carrier: choice.carrier), text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.addRoomAction.localized()) { add(choice, link: linkText) }
                Button(L10n.vkSignInAction.localized()) {
                    vkSignInFor = choice
                    showVKLogin = true
                }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: { _ in
                Text(L10n.addRoomVKHowTo.localized())
            }
        }
    }

    private func tap(_ choice: AddRoomChoice) {
        switch choice.need {
        case .nothing, .accountForm:
            add(choice, link: nil)
        case .yandexSignIn:
            signInFor = choice
        case .callLink:
            linkText = ""
            linkFor = choice
        case .unavailable:
            break   // the row is disabled; nothing to offer
        }
    }

    private func add(_ choice: AddRoomChoice, link: String?) {
        dismiss()
        onAdd(choice, link)
    }
}

/// One service: its name, how many rooms it has and what one more needs, and
/// the button that adds it.
private struct AddRoomRow: View {
    let choice: AddRoomChoice
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(CarrierTransportMatrix.carrierLabel(choice.carrier))
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Metrics.s2)
            OlcButton(buttonTitle, role: isDisabled ? .secondary : .primary, compact: true, action: onTap)
                .disabled(isDisabled)
        }
        .padding(.vertical, Theme.Metrics.s1)
        .accessibilityElement(children: .combine)
    }

    /// A full service takes no more rooms, and a closed one cannot be added to.
    private var isDisabled: Bool {
        choice.isFull || choice.need == .unavailable
    }

    private var status: String {
        let count = choice.rooms == 0
            ? L10n.addRoomNotYet.localized()
            : L10n.addRoomCount_fmt.formatted(choice.rooms)
        if choice.isFull { return L10n.addRoomFull_fmt.formatted(choice.rooms) }
        let need: String
        switch choice.need {
        case .nothing:      need = L10n.addRoomNeedNothing.localized()
        case .yandexSignIn: need = L10n.addRoomNeedYandex.localized()
        case .callLink:     need = L10n.addRoomNeedLink.localized()
        case .accountForm:  need = L10n.addRoomNeedWB.localized()
        case .unavailable:  need = L10n.addRoomNeedWBClosed.localized()
        }
        return "\(count) · \(need)"
    }

    private var buttonTitle: String {
        switch choice.need {
        case .yandexSignIn: return L10n.addRoomSignIn.localized()
        case .callLink:     return L10n.addRoomPasteLink.localized()
        case .accountForm:  return L10n.addRoomSetUp.localized()
        case .nothing, .unavailable: return L10n.addRoomAction.localized()
        }
    }
}
