import SwiftUI
import WebKit

// MARK: - WBLoginView
//
// The ONE place a WB Stream password is ever typed — and it is typed into the
// service's own page, never into a field of ours. The proven pattern from
// YandexLoginView / VKLoginView, applied to WB Stream: the human signs in ONCE
// in a real web view and the app then reuses the account token that sign-in
// produced (WBSessionStore → WBStreamRoomService). The same value is the
// account token the server config needs (`auth.token`), so signing in here is
// also what makes the data channel work without any manual copying.
//
// WHERE THE TOKEN COMES FROM: WB Stream's SPA does not reliably write
// `wb_access_token` into a cookie — it authenticates its own API calls with an
// `Authorization: Bearer` header (the reference project sniffs that header and
// manufactures the cookie itself). This view watches BOTH: an injected
// document-start script reports every Authorization header the page sends, and
// a cookie poll remains as the fallback. Either is accepted only once the page
// has left `/login` — a guest token is shape-identical to an account one, so
// the URL is the only gate there is.
//
// SECURITY mirrors VKLoginView: the warning is above the web view, the host of
// whatever is displayed is on screen, the value is never logged and never put
// in an error message, the web-view jar keeps its copy until "sign out" purges
// both — and a rejected session is cleared from both, so the next open of this
// sheet can only end in a real sign-in. The sheet's own "Sign out" button
// purges the WB cookies and loads the sign-in page again, so a web session the
// app does not hold can always be cleared from where it is seen.

struct WBLoginView: View {
    /// Called at most once, with the raw account token (`wb_access_token`
    /// value, or the Bearer value stripped of its prefix). The caller stores
    /// it (Keychain) — this view keeps no copy.
    let onSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Belt-and-braces against a re-created representable firing twice; the
    /// coordinator has its own guard.
    @State private var captured = false
    /// The host of the page currently on screen.
    @State private var host = ""
    /// Bumped by the toolbar's sign-out; the web view acts on a change.
    @State private var signOutTick = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                warning
                addressLine
                Divider()
                WBAuthWebView(signOutTick: signOutTick, onHost: { host = $0 }) { value in
                    guard !captured else { return }
                    captured = true
                    onSession(value)
                    dismiss()
                }
            }
            .navigationTitle(L10n.wbLoginTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel.localized()) { dismiss() }
                }
                // The way out of a web session the app does not use: the page
                // may show the user signed in while the app holds nothing.
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.wbLoginSignOutAction.localized()) { signOutTick += 1 }
                }
            }
        }
    }

    /// The one line the user must read before they type a password.
    private var warning: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Theme.Palette.orange)
            Text(L10n.wbLoginWarning.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.vertical, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
    }

    /// The address bar: host only, for the same reason as VKLoginView's.
    private var addressLine: some View {
        HStack(spacing: Theme.Metrics.s2) {
            Image(systemName: "lock.fill")
            Text(host.isEmpty ? "…" : host)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.mono)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.bottom, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The web view

/// A `WKWebView` on the shared (persistent) data store that watches TWO
/// signals, because WB Stream's SPA does not reliably write its account token
/// into a cookie (the reference project sniffs `Authorization: Bearer` headers
/// and manufactures the cookie itself):
///   • a document-start script hooks `fetch`/`XMLHttpRequest` and reports every
///     `Authorization` header the page sends — the token the SPA itself uses;
///   • a once-a-second cookie poll remains as the fallback (`wb_access_token`
///     does appear in some flows).
/// Both are accepted only once the page has LEFT `/login` — a guest token and
/// an account token are shape-identical on this service, so the URL is the
/// only gate there is.
private struct WBAuthWebView: UIViewRepresentable {
    /// WB Stream's sign-in page.
    static let authURL = URL(string: "https://stream.wb.ru/login")!

    /// Changes when the toolbar's sign-out is tapped.
    let signOutTick: Int
    /// Called on every committed navigation with the host being displayed.
    let onHost: (String) -> Void
    let onSessionCookie: (String) -> Void

    /// The message-handler name the injected script posts `Authorization`
    /// header values to.
    private static let bearerHandlerName = "wbBearer"

    /// Hooked at document start, before the SPA's own scripts run. Reports each
    /// DISTINCT Authorization value at most once to native code; the value is
    /// the whole header ("Bearer <token>"), stripped on the native side.
    private static let bearerSniffer = """
    (function() {
      if (window.__wbBearerHooked) return;
      window.__wbBearerHooked = true;
      var send = function(value) {
        if (!value) return;
        if (window.__wbLastBearer === value) return;
        window.__wbLastBearer = value;
        try { window.webkit.messageHandlers.wbBearer.postMessage(value); } catch (e) {}
      };
      var readHeaders = function(h) {
        try {
          if (!h) return;
          if (typeof h.get === 'function') { send(h.get('Authorization')); return; }
          send(h['Authorization'] || h['authorization']);
        } catch (e) {}
      };
      var of = window.fetch;
      if (of) {
        window.fetch = function(input, init) {
          try { readHeaders(init && init.headers); } catch (e) {}
          try { if (input && input.headers) readHeaders(input.headers); } catch (e) {}
          return of.apply(this, arguments);
        };
      }
      var origSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        try {
          if (String(name).toLowerCase() === 'authorization') send(String(value));
        } catch (e) {}
        return origSet.apply(this, arguments);
      };
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(signOutTick: signOutTick, onHost: onHost, onSessionCookie: onSessionCookie)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The DEFAULT store is the one the service's own page writes into and
        // the one this view polls.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bearerSniffer, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: Self.bearerHandlerName)
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = VKCallRoomService.desktopUserAgent
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.authURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Keep the callbacks fresh: `makeCoordinator` runs once, but the View
        // struct (and the closures it captured) is rebuilt on every render.
        let coordinator = context.coordinator
        coordinator.onSessionCookie = onSessionCookie
        coordinator.onHost = onHost
        if coordinator.handledSignOutTick != signOutTick {
            coordinator.handledSignOutTick = signOutTick
            coordinator.signOut()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController
            .removeScriptMessageHandler(forName: bearerHandlerName)
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Once a second: fast enough that the sheet closes as the redirect
        /// settles, slow enough to cost nothing.
        private static let pollSeconds: TimeInterval = 1

        var onSessionCookie: (String) -> Void
        var onHost: (String) -> Void
        /// The sign-out tick this coordinator has already acted on.
        var handledSignOutTick: Int
        /// The page on screen.
        weak var webView: WKWebView?
        private var timer: Timer?
        private var reported = false
        /// Set once the page has LEFT `/login`. A guest token and an account
        /// token are indistinguishable on this service, so the URL is the only
        /// gate — the same rule the reference project's joiner relies on.
        private var pastLogin = false
        /// Between a sign-out and the end of the cookie purge: nothing the old
        /// page says may be taken for a new sign-in.
        private var signingOut = false

        init(signOutTick: Int,
             onHost: @escaping (String) -> Void,
             onSessionCookie: @escaping (String) -> Void) {
            self.handledSignOutTick = signOutTick
            self.onHost = onHost
            self.onSessionCookie = onSessionCookie
        }

        deinit { timer?.invalidate() }

        /// Report the host the moment the response that will be RENDERED is
        /// committed — the same moment a browser's address bar switches.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
            notePage(webView)
        }

        /// Polling starts only after the first page has actually loaded. A user
        /// whose session is still valid is signed in the moment the page
        /// resolves — which is the right outcome.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
            notePage(webView)
            start()
        }

        /// The injected script's report: an `Authorization` header value the
        /// page itself sent. Arrives only for headers the SPA actually uses,
        /// which is exactly the token worth keeping.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard !reported, !signingOut, pastLogin,
                  let header = message.body as? String else { return }
            // The whole header arrives ("Bearer <token>"); the store's
            // normalize takes it from either form.
            accept(header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : header)
        }

        private func notePage(_ webView: WKWebView) {
            // The verified recipe: the service's own host, and a page that is
            // not the sign-in one. Matching the path on a bare "login"
            // substring also gated a room or asset URL that merely CONTAINS
            // it; the prefix test on this exact host is the gate that was
            // actually verified.
            if let url = webView.url,
               url.host == "stream.wb.ru",
               !url.path.lowercased().hasPrefix("/login") {
                pastLogin = true
            }
        }

        private func accept(_ raw: String) {
            guard !reported, !signingOut, let value = WBSessionStore.normalize(raw) else { return }
            reported = true
            stop()
            onSessionCookie(value)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// The toolbar's "Sign out": forget the web session, then load the
        /// sign-in page again once the cookies are really gone. The page counts
        /// as not yet signed in — a `pastLogin` left over from the old session
        /// would let a guest token through as an account one.
        func signOut() {
            signingOut = true
            pastLogin = false
            WBSessionStore.purgeWebCookies { [weak self] in
                guard let self else { return }
                self.pastLogin = false
                self.signingOut = false
                self.webView?.load(URLRequest(url: WBAuthWebView.authURL))
            }
        }

        private func start() {
            guard timer == nil, !reported else { return }
            let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
                self?.poll()
            }
            // `.common` so the poll keeps running while the user is scrolling.
            RunLoop.main.add(t, forMode: .common)
            timer = t
            poll()
        }

        private func poll() {
            guard !reported, !signingOut, pastLogin else { return }
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.reported,
                      // The domain rule lives in the type that owns the
                      // credential — one rule, no weaker copy here.
                      let cookie = WBSessionStore.sessionCookie(in: cookies) else { return }
                self.accept(cookie.value)
            }
        }
    }
}

#if DEBUG
#Preview("WB Stream sign-in — Dark") {
    WBLoginView { _ in }
        .preferredColorScheme(.dark)
}
#Preview("WB Stream sign-in — Light") {
    WBLoginView { _ in }
        .preferredColorScheme(.light)
}
#endif
