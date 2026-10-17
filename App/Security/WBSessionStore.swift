import Foundation
import WebKit

// MARK: - WBSessionStore
//
// Keychain home of the ONE credential that lets the phone create a WB Stream
// room itself: the `wb_access_token` cookie of a signed-in stream.wb.ru account.
//
// The same pattern as VKSessionStore / YandexSessionStore: the human signs in
// ONCE in a real web view (WBLoginView), the app lifts the cookie and reuses it.
// The value is a bearer credential for the WB Stream account, so:
//
//   * Keychain ONLY. Never UserDefaults, never a file, never a backup.
//   * Never logged — not the value, not a prefix, not a length.
//   * Never put in an error message or an exported diagnostic.
//
// The same value has a second job: it is the account token the server config
// calls `auth.token` (`OlcrtcConnection.wbToken`, `OLCRTC_WB_TOKEN`), so a room
// made here carries its token along with it and the data channel works without
// the user ever seeing the value.
//
// Like VKSessionStore — and unlike YandexLoginView — the web-view jar keeps the
// cookie after capture, and "sign out" purges both copies.

@MainActor
final class WBSessionStore: ObservableObject {

    // MARK: Naming

    /// The cookie that IS the credential — what stream.wb.ru itself keeps a
    /// session in.
    nonisolated static let cookieName = "wb_access_token"

    /// Registrable domain the cookie is scoped to. The cookie may be set on
    /// `stream.wb.ru` or on `.wb.ru`; both satisfy the suffix rule below, while
    /// a look-alike host (`evilwb.ru`) never does.
    nonisolated static let cookieDomain = "wb.ru"

    // House convention: `olcrtc.vk.session`, `olcrtc.yandex.session`.
    nonisolated private static let keychainService = "olcrtc.wb.session"
    nonisolated private static let keychainAccount = "wb_access_token"

    // MARK: Observable state

    /// Whether an account is linked. The ONLY thing about the credential that is
    /// ever published, logged or shown.
    @Published private(set) var hasSession: Bool = false

    init() {
        hasSession = Self.hasStoredSession()
    }

    // MARK: Read / write

    /// Stores the `wb_access_token` cookie value, replacing any previous one.
    /// A value that does not survive `normalize` is REJECTED without touching
    /// what is already stored. Returns whether the Keychain write happened.
    @discardableResult
    func save(_ token: String) -> Bool {
        guard let value = Self.normalize(token) else {
            LogStore.shared.log(.provisioning,
                "⚠ WB Stream sign-in ignored: the value is not a usable session token")
            return false
        }
        let ok = KeychainHelper.set(value,
                                    service: Self.keychainService,
                                    account: Self.keychainAccount)
        if ok { hasSession = true }
        LogStore.shared.log(.provisioning,
            ok ? "🔗 WB Stream account linked (token stored in Keychain)"
               : "⚠ Could not store the WB Stream token in the Keychain")
        return ok
    }

    /// Convenience for the web-view login: takes the cookie object straight from
    /// `WKHTTPCookieStore`. Rejects anything that is not the WB Stream token.
    @discardableResult
    func save(cookie: HTTPCookie) -> Bool {
        guard Self.isSessionCookie(cookie) else { return false }
        return save(cookie.value)
    }

    /// The stored token, or nil when no account is linked. A bearer credential:
    /// header only, never a log line, never an error message.
    func load() -> String? { Self.storedSession() }

    /// Unlinks the account — the user's "sign out" and the recovery from a
    /// rejected session. The web-view copy goes too.
    func clear() {
        KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        hasSession = false
        Self.purgeWebCookies()
        LogStore.shared.log(.provisioning, "🔓 WB Stream account unlinked (token removed)")
    }

    /// Re-reads the Keychain into `hasSession`.
    func refresh() { hasSession = Self.hasStoredSession() }

    // MARK: Nonisolated readers (for service code)

    /// The stored token, readable from any isolation domain.
    /// `WBStreamRoomService` runs off MainActor and needs exactly this.
    nonisolated static func storedSession() -> String? {
        guard let raw = KeychainHelper.get(service: keychainService, account: keychainAccount)
        else { return nil }
        return normalize(raw)
    }

    /// Whether an account is linked — the only fact that is safe to log.
    nonisolated static func hasStoredSession() -> Bool { storedSession() != nil }

    /// The credential for a create call: the Keychain item when it exists, else
    /// the token still sitting in the web view's jar. A jar value is VERIFIED
    /// against the service before it is adopted into the Keychain (the same
    /// rule as VKSessionStore): an unverified adoption of a stale or guest
    /// value left the app "signed in" with a token whose first create was
    /// already refused.
    nonisolated static func resolvedSession() async -> String? {
        if let stored = storedSession() { return stored }
        guard let value = await webSessionCookie(),
              let clean = normalize(value),
              await WBStreamRoomService.sessionIsValid(clean) else { return nil }
        KeychainHelper.set(clean, service: keychainService, account: keychainAccount)
        return clean
    }

    // MARK: Web cookie store

    /// The `wb_access_token` currently in WebKit's persistent jar, or nil. Only
    /// the value crosses the continuation — never the cookie object.
    nonisolated static func webSessionCookie() async -> String? {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: sessionCookie(in: cookies)?.value)
            }
        }
    }

    /// Drops every wb.ru cookie from WebKit's persistent store when the user
    /// signs out. Fire-and-forget, like the deletes in YandexLoginView.
    ///
    /// `completion`, when given, runs on the main queue once every delete has
    /// finished, so the sign-in sheet can reload its page without racing the
    /// purge.
    ///
    /// The cookies are only half of the sign-in: WB Stream's SPA authenticates
    /// with a Bearer token it keeps in page storage (localStorage / IndexedDB),
    /// which a cookie delete cannot reach — after a cookie-only purge the page
    /// stays signed in and the Bearer sniffer simply captures the same account
    /// again. The site data of the WB hosts goes too. Only those records, never
    /// the whole shared store: Yandex and VK sit in it as well.
    nonisolated static func purgeWebCookies(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        let store = dataStore.httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where isWBDomain(cookie.domain) {
                group.enter()
                store.delete(cookie, completionHandler: { group.leave() })
            }
            group.enter()
            DispatchQueue.main.async {
                let types = WKWebsiteDataStore.allWebsiteDataTypes()
                dataStore.fetchDataRecords(ofTypes: types) { records in
                    let wb = records.filter { isWBDomain($0.displayName) }
                    guard !wb.isEmpty else {
                        group.leave()
                        return
                    }
                    dataStore.removeData(ofTypes: types, for: wb) { group.leave() }
                }
            }
            group.notify(queue: .main) { completion?() }
        }
    }

    /// PURE. A WB host: `wb.ru` (or a subdomain — `stream.wb.ru` included) AND
    /// `wildberries.ru` (or a subdomain). The suffix rule keeps `evilwb.ru` /
    /// `evilwildberries.ru` out. The second family is not hypothetical: the
    /// reference project's `WBSTREAM_COOKIE_DOMAINS` is exactly
    /// `['stream.wb.ru','wb.ru','wildberries.ru']`, and a login that sets the
    /// cookie on `.wildberries.ru` was invisible to the narrower rule.
    nonisolated static func isWBDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d == cookieDomain || d.hasSuffix("." + cookieDomain)
            || d == "wildberries.ru" || d.hasSuffix(".wildberries.ru")
    }

    // MARK: Pure helpers

    /// PURE. Reduces whatever a human or a cookie jar hands us to a bare token
    /// value, or nil when it cannot be one. Same rules as
    /// `YandexSessionStore.normalize` (RFC 6265 cookie-octet only — the value is
    /// interpolated into a request header, so a stray CR/LF would be header
    /// injection).
    nonisolated static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = cookieName + "="
        if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let usable = value.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value < 0x7F &&
            scalar != ";" && scalar != "," && scalar != "\"" && scalar != "\\"
        }
        return usable ? value : nil
    }

    /// PURE. Is this the WB Stream token cookie? Name must match exactly, the
    /// value must be non-empty, and the domain must be a WB one (see
    /// `isWBDomain`).
    nonisolated static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == cookieName, !cookie.value.isEmpty else { return false }
        return isWBDomain(cookie.domain)
    }

    /// PURE. Picks the WB Stream token cookie out of a web view's jar.
    nonisolated static func sessionCookie(in cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { isSessionCookie($0) }
    }
}
