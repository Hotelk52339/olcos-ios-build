import Foundation

// MARK: - WBStreamRoom

/// A freshly created WB Stream room.
///
/// Both values are wanted downstream: the room id is `OlcrtcConnection.roomID`
/// for wbstream, and the token is the account credential the server config
/// calls `auth.token` (`OLCRTC_WB_TOKEN`). They travel together because the
/// room was made BY that account.
struct WBStreamRoom: Equatable, Sendable {
    /// The bare room id — exactly what the server config takes.
    let roomID: String
    /// The `wb_access_token` value this room was made with. A bearer credential:
    /// header and Keychain only, never a log line, never an error message.
    let token: String
}

// MARK: - WBStreamRoomError

/// Everything that can go wrong creating a room, in the shape a view can ACT on:
/// sign in, wait, retry, or report. No case ever carries the account token, the
/// request headers or the response body — only a status code, which is safe.
enum WBStreamRoomError: LocalizedError, Equatable {
    /// No WB Stream account has been linked yet — nothing to authenticate with.
    case noSession
    /// HTTP 401: the stored `wb_access_token` is expired or revoked. The user
    /// must sign in again; there is nothing the app can retry.
    case sessionRejected
    /// HTTP 403 / 429 / 503: WB Stream is refusing the request for now. Waiting
    /// can fix it.
    case rateLimited
    /// The request never got an answer (offline, DNS poisoned, host blocked).
    case networkUnavailable
    /// A 2xx whose body is not the `{"roomId": …}` we know how to read.
    case malformedResponse
    /// Any other HTTP status, carried so the log and the alert can name it.
    case serviceError(status: Int)

    var errorDescription: String? {
        switch self {
        case .noSession:            return L10n.wbErrNoAccount.localized()
        case .sessionRejected:      return L10n.wbErrSessionRejected.localized()
        case .rateLimited:          return L10n.wbErrRateLimited.localized()
        case .networkUnavailable:   return L10n.wbErrNetwork.localized()
        case .malformedResponse:    return L10n.wbErrMalformed.localized()
        case .serviceError(let s):  return L10n.wbErrStatus_fmt.formatted(s)
        }
    }

    /// Whether the only way out is for the user to (re-)link a WB Stream
    /// account — the view uses this to jump straight to the sign-in sheet
    /// instead of offering a pointless "retry".
    var needsSignIn: Bool {
        self == .noSession || self == .sessionRejected
    }
}

// MARK: - WBStreamRoomService
//
// One button's worth of API: create a fresh WB Stream room from the phone, with
// the user's OWN WB Stream account.
//
// Why the phone and not the VPS
// -----------------------------
// The same reason as TelemostRoomService and VKCallRoomService: a room minted
// by the server is a room the phone can never learn again during a whitelist
// window. The phone creates the room and hands the id down the SSH path — and
// with it the account token the data channel needs, so the user never has to
// copy either value by hand.
//
// The request
// -----------
// ONE authenticated POST to stream.wb.ru's own room API — the call the site's
// "create room" button makes. The whole credential is the `wb_access_token`
// cookie of a signed-in account, sent as `Authorization: Bearer <value>`; there
// is no CSRF token and nothing is signed. The room is created free-for-all
// on-screen, the same defaults the site itself picks.
//
// Isolation: a nonisolated `enum` of statics, like every other stateless service
// here. Log lines hop to MainActor one at a time.

enum WBStreamRoomService {

    // MARK: Endpoint

    /// The create-room endpoint. Force-unwrapped like the other constant URLs
    /// in this codebase: a literal with no interpolation, so it cannot fail.
    static let createURL = URL(string: "https://stream.wb.ru/api-room/api/v2/room")!

    /// The body the site's own create button sends — the room's type and
    /// privacy defaults. A literal of the flow, not a credential.
    static let createBody = #"{"roomType":"ROOM_TYPE_ALL_ON_SCREEN","roomPrivacy":"ROOM_PRIVACY_FREE"}"#

    /// The same desktop-browser identity VKCallRoomService and the in-app web
    /// views present.
    private static let userAgent = VKCallRoomService.desktopUserAgent

    private static let origin  = "https://stream.wb.ru"
    private static let referer = "https://stream.wb.ru/"

    /// Direct is a plain HTTPS round trip; the tunnel leg is a vp8/datachannel
    /// carrier and needs a longer rope for the same exchange.
    private static let directTimeout: TimeInterval = 20
    private static let tunnelTimeout: TimeInterval = 40

    // MARK: Sign-in verification

    /// The account's own record — the check the site's SPA relies on to know
    /// whether its Bearer token still means anything. One GET; the token
    /// travels in `Authorization` and is never logged. Always direct: a
    /// session check has no stake in the tunnel's route.
    static let userInfoURL = URL(string: "https://stream.wb.ru/auth/api/v1/user/info")!

    /// True only when the service answered 200 for this token.
    static func sessionIsValid(_ token: String) async -> Bool {
        await sessionState(token) == .alive
    }

    /// The same check as a verdict, for callers that must not act on
    /// "no answer": 200 is alive, 401 is dead, and anything else (no network,
    /// a proxy page, a 5xx) proves nothing either way.
    static func sessionState(_ token: String) async -> AccountSessionVerdict {
        var req = URLRequest(url: userInfoURL, timeoutInterval: directTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let urlSession = SOCKSSession.make(mode: .direct, timeout: directTimeout)
        defer { urlSession.finishTasksAndInvalidate() }
        guard let (_, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse else { return .unknown }
        return verdict(userInfoStatus: http.statusCode)
    }

    /// PURE. The verdict a user/info status carries.
    static func verdict(userInfoStatus: Int) -> AccountSessionVerdict {
        switch userInfoStatus {
        case 200: return .alive
        case 401: return .rejected
        default:  return .unknown
        }
    }

    // MARK: Create

    /// Creates a new WB Stream room and returns its id together with the account
    /// token it was made with.
    ///
    /// Route: whatever the app is ALREADY using for VPS administration — the
    /// single policy of TelemostRoomService, copied, not reinvented: tunnel
    /// first when one is live, direct when none is. A transport failure retries
    /// once on the other route; an answer that actually arrived is never
    /// re-sent, except that a refusal received THROUGH the tunnel gets one
    /// direct retry — the same rule TelemostRoomService applies: the refusal may
    /// be about the exit's address.
    static func createRoom() async throws -> WBStreamRoom {
        guard let token = await WBSessionStore.resolvedSession() else {
            await log("WB Stream: cannot create a room — no WB Stream account is linked")
            throw WBStreamRoomError.noSession
        }

        let available = await SSHTransport.currentRoute()
        do {
            return try await createRoom(token: token, route: available)
        } catch WBStreamRoomError.networkUnavailable {
            let fallback = SSHTransport.nextRoute(attempt: 2,
                                                  previous: available,
                                                  available: available)
            guard fallback != available else { throw WBStreamRoomError.networkUnavailable }
            await log("WB Stream: retrying room creation (route: \(fallback))")
            return try await createRoom(token: token, route: fallback)
        } catch WBStreamRoomError.rateLimited where available.isTunnel {
            // The rule from TelemostRoomService: a refusal reached through
            // the tunnel is answered to the exit's datacenter address. A direct
            // path that is itself cut reports the ORIGINAL refusal.
            await log("WB Stream: the refusal may be about the exit's address — retrying directly")
            do {
                return try await createRoom(token: token, route: .direct)
            } catch WBStreamRoomError.networkUnavailable {
                throw WBStreamRoomError.rateLimited
            }
        }
    }

    /// One POST on one route. `token` is the raw `wb_access_token` value: it is
    /// written into the `Authorization` header and NOWHERE else — not into a log
    /// line, not into a thrown error (`httpShouldHandleCookies` is off, so
    /// URLSession neither substitutes a Cookie header from a jar nor persists
    /// the response's `Set-Cookie`).
    private static func createRoom(token: String,
                                   route: SSHTransport.Route) async throws -> WBStreamRoom {
        let timeout = route.isTunnel ? tunnelTimeout : directTimeout

        var req = URLRequest(url: createURL, timeoutInterval: timeout)
        req.httpBody = Data(createBody.utf8)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(userAgent,                          forHTTPHeaderField: "User-Agent")
        req.setValue("*/*",                              forHTTPHeaderField: "Accept")
        req.setValue("application/json",                 forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",                  forHTTPHeaderField: "Authorization")
        req.setValue(origin,                             forHTTPHeaderField: "Origin")
        req.setValue(referer,                            forHTTPHeaderField: "Referer")

        let urlSession = SOCKSSession.make(mode: route.isTunnel ? .tunnel : .direct,
                                           timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }

        await log("WB Stream: requesting a new room (route: \(route))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let error as URLError {
            // The URLError code is a system diagnostic, never anything of ours.
            await log("WB Stream: no answer from the API (route: \(route), URLError \(error.code.rawValue))")
            throw WBStreamRoomError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            await log("WB Stream: the API answered with a non-HTTP response")
            throw WBStreamRoomError.malformedResponse
        }

        // The documented success statuses, and only those: a 204 or a 202 is
        // not an answer that names a room.
        switch http.statusCode {
        case 200, 201:
            break
        case 401:
            await log("WB Stream: the saved account token was rejected (401)")
            throw WBStreamRoomError.sessionRejected
        case 400, 403:
            // The refusals only an account token would not get (a GUEST one
            // does — see permissionRefusal) mean the stored token cannot make
            // rooms at all: "sign in again", not an endless "retry".
            if Self.permissionRefusal(status: http.statusCode, body: data) {
                await log("WB Stream: the stored token is not allowed to create rooms (\(http.statusCode))")
                throw WBStreamRoomError.sessionRejected
            }
            await log("WB Stream: the API refused the request (\(http.statusCode))")
            throw http.statusCode == 403 ? WBStreamRoomError.rateLimited
                                         : WBStreamRoomError.serviceError(status: http.statusCode)
        case 429, 503:
            await log("WB Stream: the API refused the request (\(http.statusCode))")
            throw WBStreamRoomError.rateLimited
        default:
            await log("WB Stream: the API returned HTTP \(http.statusCode)")
            throw WBStreamRoomError.serviceError(status: http.statusCode)
        }

        // A successful transfer through the tunnel counts as tunnel activity, so
        // keep-alive skips its next probe (same contract as IPChecker/SpeedTest).
        if route.isTunnel { SOCKSSession.noteTunnelActivity() }

        let roomID = try await decodeOrLog(data)
        await log("WB Stream: new room created — \(roomID)")
        return WBStreamRoom(roomID: roomID, token: token)
    }

    // MARK: Pure parsing

    /// PURE. Whether a 400/403 body is one of the refusals only a token
    /// WITHOUT an account behind it gets — the answers to map to
    /// "sign in again" instead of a retry the same token would lose again.
    ///
    /// WB Stream's API is a gRPC gateway, so every error body is
    /// `{"code":<grpc>,"message":"…","details":[]}`. Verified live
    /// (2026-10-16): a guest token on create answers
    /// `400 {"code":3,"message":"Guests are not allowed to create room"}`;
    /// a permission denial is `403` with code 7 (PermissionDenied). A plain
    /// `400 {"code":3,"message":"invalid CreateRoomV2Request…"}` is protobuf
    /// validation, not a verdict about the token — only the full guest wording
    /// (a lone "guest" word in an unrelated message must not send anyone to
    /// re-login) and the 403/7 pair count.
    static func permissionRefusal(status: Int, body: Data) -> Bool {
        guard status == 400 || status == 403,
              let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        else { return false }
        if (payload.message ?? "").lowercased().contains("guests are not allowed") { return true }
        guard let code = payload.code else { return false }
        return status == 403 && code == 7
    }

    /// The gRPC-gateway error envelope. Optional fields so a foreign body
    /// decodes cleanly to nil rather than throwing.
    struct ErrorEnvelope: Decodable {
        let code: Int?
        let message: String?
    }

    /// PURE. Decodes the create-room response: `{"roomId":"…"}`. Anything else —
    /// a different shape, a missing/empty id, plain HTML from an interception
    /// page — is `.malformedResponse`.
    ///
    /// The id is also charset-checked (`A-Z a-z 0-9 - _`), the same guard
    /// `TelemostRoomService.roomID(fromURI:)` applies: this value is about to be
    /// written into the server's `server.yaml` through an SSH command line, so
    /// refusing an id we do not recognise is safer than leaning on
    /// `SSHRunner.shellSafe` to strip it afterwards.
    static func decodeRoomID(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(RoomResponse.self, from: data),
              let raw = payload.roomId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.allSatisfy({ ch in
                  ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
              })
        else { throw WBStreamRoomError.malformedResponse }
        return raw
    }

    /// The `{"roomId": …}` envelope. Optional so a foreign body decodes cleanly
    /// to nil and becomes `.malformedResponse` rather than a decoding throw.
    struct RoomResponse: Decodable {
        let roomId: String?
    }

    // MARK: Logging

    private static func decodeOrLog(_ data: Data) async throws -> String {
        do {
            return try decodeRoomID(data)
        } catch {
            // Byte count only — the body could carry account-scoped fields.
            await log("WB Stream: the API answered with an unreadable body (\(data.count) bytes)")
            throw WBStreamRoomError.malformedResponse
        }
    }

    /// Every line here is engineering English and MUST stay free of the account
    /// token; `LogStore.log` also runs `redactSecrets` as a second net.
    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}
