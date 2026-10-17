import XCTest
@testable import olcrtc_ios

// WB Stream is closed to regular accounts (CarrierAvailability), and the app says
// so instead of offering what cannot work. The screens that hide a sign-in or an
// automatic room key off the same flag through `wbStreamOpen:` parameters and are
// tested where they live (AddRoomChoiceTests, AddServerFlowTests, NewCarriersTests,
// RoomRotationTests); this file pins the wording the user is left with, and the
// one view helper that has no test of its own.
//
// NATIVE-ONLY (not covered here, by design): that the WB card shows its notice
// instead of the sign-in, that the Service accounts row hides its sign-in button
// and keeps the reset action, and that the Add-a-room row is disabled — they are
// SwiftUI layout over the pure decisions tested above.

@MainActor
final class WBStreamClosedTests: XCTestCase {

    private let tables: [(language: String, table: [L10n: String], closed: String)] = [
        ("en", L10nTable.english, "closed"),
        ("ru", L10nTable.russian, "закрыт"),
        ("fr", L10nTable.french, "fermé"),
    ]

    /// The strings that used to send people to stream.wb.ru to make a room.
    func testTheStringsThatPromisedARoomNowSayWBStreamIsClosedAndPointElsewhere() throws {
        try XCTSkipIf(CarrierAvailability.wbStreamOpen, "WB Stream is open: the earlier wording is back")
        let keys: [L10n] = [.roomIDWbstreamHint, .wbTokenFooter, .addFlowWBBody, .accountsWBBody]
        for entry in tables {
            for key in keys {
                let text = entry.table[key] ?? ""
                let label = "[\(entry.language)] \(key.rawValue)"
                XCTAssertTrue(text.lowercased().contains(entry.closed), label)
                XCTAssertTrue(text.contains("VK Calls") && text.contains("Jitsi"), label)
                XCTAssertFalse(text.contains("stream.wb.ru"), label)
            }
        }
    }

    func testEveryOtherWBNoticeSaysItIsClosedToo() throws {
        try XCTSkipIf(CarrierAvailability.wbStreamOpen, "WB Stream is open: the earlier wording is back")
        let keys: [L10n] = [.carrierWbstreamDesc, .wbStreamClosedTitle, .wbStreamClosedStatus,
                            .addFlowWBClosed, .addRoomNeedWBClosed, .roomRotationNoteClosed]
        for entry in tables {
            for key in keys {
                let text = entry.table[key] ?? ""
                XCTAssertTrue(text.lowercased().contains(entry.closed), "[\(entry.language)] \(key.rawValue)")
            }
        }
    }

    /// The wizard's protocol step follows the shipped flag through its defaults.
    func testTheWizardFollowsTheShippedFlag() {
        let badge: AddServerCarrierBadge = CarrierAvailability.wbStreamOpen ? .alternative : .none
        XCTAssertEqual(AddServerCarrierPlan.badge(for: "wbstream"), badge)
        XCTAssertEqual(AddServerCarrierPlan.requirement(for: "wbstream") == nil, CarrierAvailability.wbStreamOpen)
    }

    func testWBStreamRoomsAreNotMadeAutomaticallyWhileItIsClosed() {
        // Even with an account linked, and whatever the other accounts say.
        XCTAssertFalse(ServersView.makesRooms("wbstream", yandex: true, vk: true, wb: true, wbStreamOpen: false))
        XCTAssertTrue(ServersView.makesRooms("wbstream", yandex: false, vk: false, wb: true, wbStreamOpen: true))
        XCTAssertFalse(ServersView.makesRooms("wbstream", yandex: true, vk: true, wb: false, wbStreamOpen: true))
    }

    func testTheFlagTouchesNoOtherServicesAutomaticRooms() {
        for open in [false, true] {
            XCTAssertTrue(ServersView.makesRooms("jitsi", yandex: false, vk: false, wb: false, wbStreamOpen: open))
            XCTAssertTrue(ServersView.makesRooms("salutejazz", yandex: false, vk: false, wb: false, wbStreamOpen: open))
            XCTAssertTrue(ServersView.makesRooms("vkcalls", yandex: false, vk: true, wb: false, wbStreamOpen: open))
            XCTAssertFalse(ServersView.makesRooms("vkcalls", yandex: true, vk: false, wb: true, wbStreamOpen: open))
            XCTAssertTrue(ServersView.makesRooms("telemost", yandex: true, vk: false, wb: false, wbStreamOpen: open))
        }
    }
}
