import SwiftUI

// MARK: - ServiceAccountsView
//
// Settings → Service accounts: what each call service needs before a server
// can sit in its rooms, and the accounts the app itself holds — Yandex (for
// Telemost rooms), VK (for VK calls) and WB Stream (for rooms and their account
// token). Each linked account lets the app make that service's rooms by itself;
// every manual path stays listed as the fallback. SaluteJazz and Jitsi need
// nothing at all. WB Stream is closed to regular accounts right now
// (CarrierAvailability): its row says so and offers no sign-in.
//
// Yandex, VK and WB Stream always offer a way out. The in-app web view keeps
// its own sign-in, so it can show an account as signed in while the Keychain
// holds nothing (a sign-in the app could not verify is never stored, and a
// Yandex sheet closed half-way leaves its cookies behind) — and with no stored
// session there is no "Sign out". "Reset sign-in in the browser" is that
// sign-out: it forgets the web view's session and any stored one.

struct ServiceAccountsView: View {
    @StateObject private var yandex = YandexSessionStore()
    @StateObject private var vk = VKSessionStore()
    @StateObject private var wb = WBSessionStore()
    @State private var showYandexLogin = false
    @State private var showVKLogin = false
    @State private var showWBLogin = false
    /// Which account a destructive sign-out is confirming ("vkcalls"/"wbstream").
    @State private var signOutTarget: String?
    /// Which account the browser reset is confirming ("telemost"/"vkcalls"/"wbstream").
    @State private var resetTarget: String?
    @State private var confirmYandexSignOut = false

    var body: some View {
        Form {
            Section {
                row(carrier: "telemost",
                    status: yandex.hasSession ? L10n.accountSignedIn.localized()
                                              : L10n.accountSignedOut.localized(),
                    detail: L10n.accountsYandexBody.localized())
                if yandex.hasSession {
                    Button(L10n.accountsSignOutAction.localized(), role: .destructive) { confirmYandexSignOut = true }
                } else {
                    Button(L10n.telemostRoomSignInAction.localized()) { showYandexLogin = true }
                    Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "telemost" }
                }
            }
            .signalFormRows()

            Section {
                row(carrier: "vkcalls",
                    status: vk.hasSession ? L10n.accountSignedIn.localized()
                                          : L10n.accountSignedOut.localized(),
                    detail: L10n.accountsVKBody.localized())
                if vk.hasSession {
                    Button(L10n.signOutAction_fmt.formatted(CarrierTransportMatrix.carrierLabel("vkcalls")),
                           role: .destructive) { signOutTarget = "vkcalls" }
                } else {
                    Button(L10n.vkSignInAction.localized()) { showVKLogin = true }
                    Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "vkcalls" }
                }
            }
            .signalFormRows()

            Section {
                row(carrier: "wbstream", status: wbStatus, detail: L10n.accountsWBBody.localized())
                if wb.hasSession {
                    Button(L10n.signOutAction_fmt.formatted(CarrierTransportMatrix.carrierLabel("wbstream")),
                           role: .destructive) { signOutTarget = "wbstream" }
                } else {
                    // No sign-in is offered while WB Stream is closed to regular
                    // accounts; the way out of one the browser still holds stays.
                    if CarrierAvailability.wbStreamOpen {
                        Button(L10n.wbSignInAction.localized()) { showWBLogin = true }
                    }
                    Button(L10n.accountsResetBrowserAction.localized()) { resetTarget = "wbstream" }
                }
            }
            .signalFormRows()

            Section {
                row(carrier: "salutejazz", status: L10n.addFlowNoAccount.localized(),
                    detail: L10n.accountsSaluteBody.localized())
                row(carrier: "jitsi", status: L10n.addFlowNoAccount.localized(),
                    detail: L10n.accountsJitsiBody.localized())
            } header: {
                SignalSectionHeader(L10n.accountsOthersHeader.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.accountsTitle.localized())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            yandex.refresh()
            vk.refresh()
            wb.refresh()
        }
        .sheet(isPresented: $showYandexLogin) {
            YandexLoginView { session in
                showYandexLogin = false
                _ = yandex.save(session)
            }
        }
        .sheet(isPresented: $showVKLogin) {
            VKLoginView { session in
                showVKLogin = false
                _ = vk.save(session)
            }
        }
        .sheet(isPresented: $showWBLogin) {
            WBLoginView { token in
                showWBLogin = false
                _ = wb.save(token)
            }
        }
        .confirmationDialog(L10n.accountsSignOutTitle.localized(), isPresented: $confirmYandexSignOut,
                            titleVisibility: .visible) {
            Button(L10n.accountsSignOutAction.localized(), role: .destructive) { yandex.clear() }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: {
            Text(L10n.accountsSignOutMessage.localized())
        }
        .confirmationDialog(
            signOutTarget.map { L10n.signOutConfirmTitle_fmt.formatted(CarrierTransportMatrix.carrierLabel($0)) } ?? "",
            isPresented: Binding(get: { signOutTarget != nil },
                                 set: { if !$0 { signOutTarget = nil } }),
            titleVisibility: .visible,
            presenting: signOutTarget
        ) { carrier in
            Button(L10n.signOutAction_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)),
                   role: .destructive) {
                if carrier == "vkcalls" { vk.clear() } else { wb.clear() }
            }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: { carrier in
            Text(L10n.signOutConfirmMessage_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
        }
        .confirmationDialog(
            resetTarget.map { L10n.accountsResetBrowserTitle_fmt.formatted(CarrierTransportMatrix.carrierLabel($0)) } ?? "",
            isPresented: Binding(get: { resetTarget != nil },
                                 set: { if !$0 { resetTarget = nil } }),
            titleVisibility: .visible,
            presenting: resetTarget
        ) { carrier in
            // `clear()` is the whole reset: the Keychain item (if any) and the
            // web view's copy of the sign-in, so the next sign-in starts from
            // scratch.
            Button(L10n.accountsResetBrowserAction.localized(), role: .destructive) {
                switch carrier {
                case "telemost": yandex.clear()
                case "vkcalls":  vk.clear()
                default:         wb.clear()
                }
            }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: { carrier in
            Text(L10n.accountsResetBrowserMessage_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
        }
    }

    /// WB Stream's status line. While the service is closed to regular
    /// accounts "signed in" would promise rooms the account can no longer make.
    private var wbStatus: String {
        guard CarrierAvailability.wbStreamOpen else { return L10n.wbStreamClosedStatus.localized() }
        return wb.hasSession ? L10n.accountSignedIn.localized() : L10n.accountSignedOut.localized()
    }

    private func row(carrier: String, status: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            HStack {
                Text(CarrierTransportMatrix.carrierLabel(carrier))
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: Theme.Metrics.s2)
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Metrics.s1)
    }
}
