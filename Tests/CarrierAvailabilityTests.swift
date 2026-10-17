import XCTest
@testable import olcrtc_ios

// The one switch behind every "WB Stream is closed" decision. The screens and
// jobs that key off it are tested in their own files, against both states of
// the flag through their `wbStreamOpen:` parameters.

final class CarrierAvailabilityTests: XCTestCase {

    /// Update this together with the flag when WB reopens.
    func testWBStreamShipsClosed() {
        XCTAssertFalse(CarrierAvailability.wbStreamOpen)
        XCTAssertFalse(CarrierAvailability.isOpen("wbstream"))
    }

    func testOnlyWBStreamFollowsTheFlag() {
        for carrier in ["telemost", "vkcalls", "salutejazz", "jitsi", "a-future-service"] {
            XCTAssertTrue(CarrierAvailability.isOpen(carrier, wbStreamOpen: false), carrier)
            XCTAssertTrue(CarrierAvailability.isOpen(carrier, wbStreamOpen: true), carrier)
        }
        XCTAssertFalse(CarrierAvailability.isOpen("wbstream", wbStreamOpen: false))
        XCTAssertTrue(CarrierAvailability.isOpen("wbstream", wbStreamOpen: true))
    }
}
