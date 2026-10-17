import XCTest
@testable import olcrtc_ios

/// "Speed up: add a room": which services the sheet lists, how many rooms each
/// has and what one more needs — which depends on the accounts the app holds
/// (Yandex, VK, WB Stream), not only on the service, and on whether WB Stream
/// is open to regular accounts at all (CarrierAvailability). The tests that are
/// about WB Stream's account pass `wbStreamOpen: true` so they keep describing
/// the open service whatever the shipped flag says.
final class AddRoomChoiceTests: XCTestCase {
    func testEveryCallServiceIsListedThoseThatNeedNothingFirst() {
        let choices = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                         vkSignedIn: false, wbSignedIn: false, wbStreamOpen: true)
        XCTAssertEqual(choices.map(\.carrier), ["jitsi", "salutejazz", "telemost", "vkcalls", "wbstream"])
        XCTAssertEqual(choices.map(\.need),
                       [.nothing, .nothing, .yandexSignIn, .callLink, .accountForm])
        XCTAssertTrue(choices.allSatisfy { $0.rooms == 0 && !$0.isFull })
    }

    func testTelemostNeedsNothingOnceSignedIn() {
        let telemost = AddRoomChoice.make(rooms: [:], yandexSignedIn: true,
                                          vkSignedIn: false, wbSignedIn: false)
            .first { $0.carrier == "telemost" }
        XCTAssertEqual(telemost?.need, .nothing)
    }

    func testVKNeedsNothingOnceSignedIn() {
        let signedIn = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                          vkSignedIn: true, wbSignedIn: false)
        XCTAssertEqual(signedIn.first { $0.carrier == "vkcalls" }?.need, .nothing)
        let signedOut = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                           vkSignedIn: false, wbSignedIn: false)
        XCTAssertEqual(signedOut.first { $0.carrier == "vkcalls" }?.need, .callLink)
    }

    func testWBStreamNeedsNothingOnceItsTokenExists() {
        let signedIn = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                          vkSignedIn: false, wbSignedIn: true, wbStreamOpen: true)
        XCTAssertEqual(signedIn.first { $0.carrier == "wbstream" }?.need, .nothing)
        let signedOut = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                           vkSignedIn: false, wbSignedIn: false, wbStreamOpen: true)
        XCTAssertEqual(signedOut.first { $0.carrier == "wbstream" }?.need, .accountForm)
    }

    /// Closed to regular accounts: the row stays in the list, with its reason,
    /// and offers neither a sign-in nor an automatic room — whatever the app
    /// holds, since a token it holds is no longer one the service takes.
    func testWBStreamIsListedButUnavailableWhileItIsClosed() {
        for signedIn in [false, true] {
            let choices = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                             vkSignedIn: false, wbSignedIn: signedIn, wbStreamOpen: false)
            XCTAssertEqual(choices.map(\.carrier), ["jitsi", "salutejazz", "telemost", "vkcalls", "wbstream"])
            XCTAssertEqual(choices.first { $0.carrier == "wbstream" }?.need, .unavailable)
            // The other services do not care.
            XCTAssertEqual(Array(choices.map(\.need).dropLast()),
                           [.nothing, .nothing, .yandexSignIn, .callLink])
        }
    }

    func testTheShippedFlagDecidesWhenNothingIsPassed() {
        let wb = AddRoomChoice.make(rooms: [:], yandexSignedIn: false,
                                    vkSignedIn: false, wbSignedIn: true)
            .first { $0.carrier == "wbstream" }
        let expected: AddRoomChoice.Need = CarrierAvailability.wbStreamOpen ? .nothing : .unavailable
        XCTAssertEqual(wb?.need, expected)
    }

    func testRoomCountsAndTheCap() {
        let choices = AddRoomChoice.make(rooms: ["jitsi": CarrierTransportMatrix.maxRooms, "salutejazz": 1],
                                         yandexSignedIn: false,
                                         vkSignedIn: false, wbSignedIn: false)
        let jitsi = choices.first { $0.carrier == "jitsi" }
        let salute = choices.first { $0.carrier == "salutejazz" }
        XCTAssertEqual(jitsi?.isFull, true)
        XCTAssertEqual(salute?.rooms, 1)
        XCTAssertEqual(salute?.isFull, false)
    }
}
