import SwiftUI

// MARK: - ProxyScopeCard
//
// Home, proxy mode: what "Connected" covers, and the two ways other apps take
// the tunnel — Telegram's one-tap link, and the bypass list another VPN app
// needs. Open on the page, not folded: a free Apple ID lands here on every
// first Connect, and the folded fallback line alone read as a footnote.

struct ProxyScopeCard: View {
    /// The VPN permission was refused and the proxy stands in for it.
    let isFallback: Bool
    let socksPort: Int
    /// Opens the bypass list of the live olcrtc connection; nil without one.
    var onBypassList: (() -> Void)? = nil
    let onTelegram: () -> Void

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                    Image(systemName: "app.badge.checkmark")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: Theme.Metrics.s7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                        Text(L10n.proxyScopeTitle.localized())
                            .font(Theme.Typography.bodyStrong)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text((isFallback ? L10n.proxyScopeFallbackBody : L10n.proxyScopeBody).localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.proxyScopeAddress_fmt.formatted("127.0.0.1:\(socksPort)"))
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                OlcButton(L10n.telegramProxyAction.localized(), systemImage: "paperplane.fill",
                          role: .primary, fillWidth: true, action: onTelegram)
                    .accessibilityHint(L10n.telegramProxyHint.localized())
                if let onBypassList {
                    Button(action: onBypassList) {
                        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
                            otherVPNText
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    otherVPNText
                }
            }
        }
    }

    private var otherVPNText: some View {
        Text(L10n.proxyScopeOtherVPNApp.localized())
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Telegram hand-off

enum TelegramProxyOpener {
    /// Hands the local SOCKS5 proxy to Telegram in one tap (its own "Enable
    /// proxy?" sheet) or, without Telegram installed, to the t.me page that
    /// offers it. The link is never logged: it may carry the local login.
    @MainActor
    static func open(port: Int, settings: SettingsStore) {
        let auth = settings.localSocksAuthEnabled
        let user = auth ? settings.localSocksUser : nil
        let pass = auth ? settings.localSocksPass : nil
        guard let app = TelegramProxyLink.appURL(port: port, user: user, pass: pass) else { return }
        let web = TelegramProxyLink.webURL(port: port, user: user, pass: pass)
        UIApplication.shared.open(app) { opened in
            if !opened, let web { UIApplication.shared.open(web) }
        }
    }
}
