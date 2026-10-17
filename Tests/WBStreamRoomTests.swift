import XCTest
@testable import olcrtc_ios

// WB Stream one-button room creation.
//
// Everything covered here is PURE: the room-id parser and the error taxonomy on
// `WBStreamRoomService`, and the pure halves of `WBSessionStore` (`normalize`,
// `isSessionCookie`, `sessionCookie(in:)`). The Keychain round-trip is covered
// too, snapshotting/restoring the real item per the repo convention.
//
// INTEGRATION-ONLY (not covered here, by design):
//   * `WBStreamRoomService.createRoom()` — a live authenticated POST to
//     stream.wb.ru with a real `wb_access_token`. The URL, the body literal and
//     the status mapping are pinned below.
//   * The route choice (`SSHTransportTests` already covers it).
//
// SECURITY NOTE: no test here may ever assert on a real token, and none of the
// fixtures is a real one.

// MARK: - Room id parsing

final class WBStreamRoomDecoderTests: XCTestCase {

    func testDecodeRoomIDReadsTheCreateAnswer() throws {
        let data = Data(#"{"roomId":"1234567890"}"#.utf8)
        XCTAssertEqual(try WBStreamRoomService.decodeRoomID(data), "1234567890")
    }

    func testDecodeRoomIDAcceptsTokenShapedIDs() throws {
        // The charset guard is `A-Z a-z 0-9 - _`, the same one Telemost ids use.
        let data = Data(#"{"roomId":"AbC-d_1"}"#.utf8)
        XCTAssertEqual(try WBStreamRoomService.decodeRoomID(data), "AbC-d_1")
    }

    func testDecodeRoomIDRejectsForeignBodies() {
        for body in ["", "{}", #"{"roomId":""}"#, #"{"roomId":"   "}"#,
                     #"{"room":"123"}"#, "<html>interception</html>"] {
            XCTAssertThrowsError(try WBStreamRoomService.decodeRoomID(Data(body.utf8))) {
                XCTAssertEqual($0 as? WBStreamRoomError, .malformedResponse)
            }
        }
    }

    func testDecodeRoomIDRejectsValuesThatCannotTravelInAnSSHCommand() {
        // This value is on its way into server.yaml through a shell command
        // line; an id the parser does not recognise is refused, not sanitized.
        for id in ["12 34", "12;34", "12\"34", "ид", "12\n34"] {
            let data = Data("{\"roomId\":\"\(id)\"}".utf8)
            XCTAssertThrowsError(try WBStreamRoomService.decodeRoomID(data),
                                 "id \(id) must be refused") {
                XCTAssertEqual($0 as? WBStreamRoomError, .malformedResponse)
            }
        }
    }
}

// MARK: - Error taxonomy

final class WBStreamRoomErrorTests: XCTestCase {

    func testNeedsSignIn() {
        XCTAssertTrue(WBStreamRoomError.noSession.needsSignIn)
        XCTAssertTrue(WBStreamRoomError.sessionRejected.needsSignIn)
        XCTAssertFalse(WBStreamRoomError.rateLimited.needsSignIn)
        XCTAssertFalse(WBStreamRoomError.networkUnavailable.needsSignIn)
    }

    func testVerdictOfAUserInfoStatus() {
        // The one GET the check makes: 200 is alive, 401 is dead, and anything
        // else — a 5xx, a proxy's 502, no HTTP at all — is no evidence.
        XCTAssertEqual(WBStreamRoomService.verdict(userInfoStatus: 200), .alive)
        XCTAssertEqual(WBStreamRoomService.verdict(userInfoStatus: 401), .rejected)
        XCTAssertEqual(WBStreamRoomService.verdict(userInfoStatus: 500), .unknown)
        XCTAssertEqual(WBStreamRoomService.verdict(userInfoStatus: 403), .unknown)
        XCTAssertEqual(WBStreamRoomService.verdict(userInfoStatus: 0), .unknown)
    }

    func testErrorMessagesNeverCarrySecrets() {
        // The cases hold no values by construction; the descriptions name only
        // the service and, at most, a status code.
        for error in [WBStreamRoomError.noSession, .sessionRejected, .rateLimited,
                      .networkUnavailable, .malformedResponse, .serviceError(status: 500)] {
            XCTAssertFalse((error.errorDescription ?? "").contains("wb_access_token"))
        }
    }
}

// MARK: - Guest / permission refusals (the 400/403 bodies that mean "sign in")

final class WBStreamPermissionRefusalTests: XCTestCase {

    /// The live 2026-10-16 probe of a guest token on create.
    func testGuestRefusalOn400Counts() {
        let body = Data(#"{"code":3,"message":"Guests are not allowed to create room","details":[]}"#.utf8)
        XCTAssertTrue(WBStreamRoomService.permissionRefusal(status: 400, body: body))
    }

    /// The permission-denial pair: HTTP 403 with gRPC code 7.
    func testPermissionDeniedOn403Counts() {
        let body = Data(#"{"code":7,"message":"guests cannot create rooms","details":[]}"#.utf8)
        XCTAssertTrue(WBStreamRoomService.permissionRefusal(status: 403, body: body))
        // Code 7 with a message that does not name guests is still the
        // documented permission denial.
        XCTAssertTrue(WBStreamRoomService.permissionRefusal(
            status: 403, body: Data(#"{"code":7,"message":"permission denied"}"#.utf8)))
    }

    /// Protobuf validation is also 400/code 3 — but it is about the REQUEST,
    /// not the token, and must stay a service error.
    func testValidationRefusalOn400DoesNotCount() {
        let body = Data(#"{"code":3,"message":"invalid CreateRoomV2Request.RoomType: value must not be in list [ROOM_TYPE_UNSPECIFIED]","details":[]}"#.utf8)
        XCTAssertFalse(WBStreamRoomService.permissionRefusal(status: 400, body: body))
    }

    func testUnauthorizedBodyDoesNotCount() {
        // 401 has its own mapping; the envelope is not a permission refusal.
        let body = Data(#"{"code":16,"message":"Bearer realm=\"auth_service\", error=\"invalid_token\"","details":[]}"#.utf8)
        XCTAssertFalse(WBStreamRoomService.permissionRefusal(status: 401, body: body))
    }

    func testOtherStatusesAndForeignBodiesDoNotCount() {
        XCTAssertFalse(WBStreamRoomService.permissionRefusal(
            status: 500, body: Data(#"{"code":3,"message":"Guests are not allowed to create room"}"#.utf8)))
        for body in ["", "{}", "<html>interception</html>", #"{"message":"Guests"}"#] {
            XCTAssertFalse(WBStreamRoomService.permissionRefusal(status: 400, body: Data(body.utf8)),
                           "body \(body) must not count")
        }
        // A guest wording on 403 counts without any code field.
        XCTAssertTrue(WBStreamRoomService.permissionRefusal(
            status: 403, body: Data(#"{"message":"Guests are not allowed to create room"}"#.utf8)))
    }
}

// MARK: - WBSessionStore: pure helpers

final class WBSessionNormalizeTests: XCTestCase {

    // Not a real token — a shape-alike fixture.
    private let fixture = "wb.fixture.2f0c1a9b8e7d6c5b"

    func testPlainValuePassesThrough() {
        XCTAssertEqual(WBSessionStore.normalize(fixture), fixture)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(WBSessionStore.normalize("  \(fixture)\n"), fixture)
    }

    func testPastedNameValuePairIsAccepted() {
        XCTAssertEqual(WBSessionStore.normalize("wb_access_token=\(fixture)"), fixture)
    }

    func testPastedCookieLineKeepsOnlyTheFirstPair() {
        XCTAssertEqual(
            WBSessionStore.normalize("wb_access_token=\(fixture); other=1"),
            fixture)
    }

    func testEmptyAndBlankAreRejected() {
        XCTAssertNil(WBSessionStore.normalize(""))
        XCTAssertNil(WBSessionStore.normalize("   \n "))
        XCTAssertNil(WBSessionStore.normalize("wb_access_token="))
    }

    func testHeaderInjectionIsRejected() {
        // The value is interpolated into a request header — CR/LF must never pass.
        XCTAssertNil(WBSessionStore.normalize("abc\r\nX-Evil: 1"))
        XCTAssertNil(WBSessionStore.normalize("abc\nX-Evil: 1"))
    }

    func testInteriorWhitespaceAndNonASCIIAreRejected() {
        XCTAssertNil(WBSessionStore.normalize("ab cd"))
        XCTAssertNil(WBSessionStore.normalize("\u{0430}\u{0431}\u{0432}"))   // Cyrillic
    }
}

final class WBSessionCookieTests: XCTestCase {

    private func makeCookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name:   name,
            .value:  value,
            .domain: domain,
            .path:   "/",
        ]))
    }

    func testPicksTheTokenCookieOutOfAJar() throws {
        let jar = [
            try makeCookie(name: "lang",            value: "1",   domain: ".wb.ru"),
            try makeCookie(name: "wb_access_token", value: "abc", domain: "stream.wb.ru"),
        ]
        XCTAssertEqual(WBSessionStore.sessionCookie(in: jar)?.value, "abc")
    }

    func testRegistrableAndSubdomainCookiesAreAccepted() throws {
        XCTAssertTrue(WBSessionStore.isSessionCookie(
            try makeCookie(name: "wb_access_token", value: "abc", domain: ".wb.ru")))
        XCTAssertTrue(WBSessionStore.isSessionCookie(
            try makeCookie(name: "wb_access_token", value: "abc", domain: "wb.ru")))
    }

    func testLookalikeDomainIsRejected() throws {
        // "evilwb.ru" ends with "wb.ru" but not with ".wb.ru".
        let cookie = try makeCookie(name: "wb_access_token", value: "abc", domain: "evilwb.ru")
        XCTAssertFalse(WBSessionStore.isSessionCookie(cookie))
        XCTAssertFalse(WBSessionStore.isWBDomain("evilwb.ru"))
        XCTAssertTrue(WBSessionStore.isWBDomain("stream.wb.ru"))
        // The reference project's domain family: a cookie set on
        // `.wildberries.ru` is as good as one on `wb.ru`.
        XCTAssertTrue(WBSessionStore.isWBDomain("wildberries.ru"))
        XCTAssertTrue(WBSessionStore.isWBDomain(".wildberries.ru"))
        XCTAssertFalse(WBSessionStore.isWBDomain("evilwildberries.ru"))
    }

    func testOtherCookieNamesAreRejected() throws {
        let cookie = try makeCookie(name: "wb_token", value: "abc", domain: ".wb.ru")
        XCTAssertFalse(WBSessionStore.isSessionCookie(cookie))
        XCTAssertNil(WBSessionStore.sessionCookie(in: [cookie]))
    }

    func testEmptyJarYieldsNil() {
        XCTAssertNil(WBSessionStore.sessionCookie(in: []))
    }
}

// MARK: - WBSessionStore: Keychain round-trip
//
// Touches the ONE real item (`olcrtc.wb.session` / `wb_access_token`), so setUp
// snapshots it and tearDown puts it back.

@MainActor
final class WBSessionStoreTests: XCTestCase {

    private var snapshot: String?
    private let fixture = "wb.fixture.2f0c1a9b8e7d6c5b"

    override func setUp() {
        super.setUp()
        snapshot = WBSessionStore.storedSession()
        WBSessionStore().clear()
    }

    override func tearDown() {
        let store = WBSessionStore()
        if let snapshot { store.save(snapshot) } else { store.clear() }
        super.tearDown()
    }

    func testStartsUnlinked() {
        XCTAssertFalse(WBSessionStore().hasSession)
        XCTAssertNil(WBSessionStore.storedSession())
    }

    func testSaveThenLoadRoundTrips() {
        let store = WBSessionStore()
        XCTAssertTrue(store.save(fixture))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
        XCTAssertEqual(WBSessionStore.storedSession(), fixture)
        XCTAssertTrue(WBSessionStore.hasStoredSession())
    }

    func testSaveNormalizesAPastedPair() {
        let store = WBSessionStore()
        XCTAssertTrue(store.save("wb_access_token=\(fixture); other=1"))
        XCTAssertEqual(store.load(), fixture)
    }

    func testUnusableValueIsRejectedWithoutClobbering() {
        let store = WBSessionStore()
        XCTAssertTrue(store.save(fixture))
        // A bad paste must never silently unlink a working account.
        XCTAssertFalse(store.save("   "))
        XCTAssertFalse(store.save("bad value\r\nX-Evil: 1"))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
    }

    func testClearRemovesTheToken() {
        let store = WBSessionStore()
        store.save(fixture)
        store.clear()
        XCTAssertFalse(store.hasSession)
        XCTAssertNil(WBSessionStore.storedSession())
    }
}
