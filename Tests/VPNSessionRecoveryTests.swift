import Network
import XCTest
@testable import olcrtc_ios

// VPNSessionRecovery: when the VPN extension holds, joins the rooms again or
// gives the tunnel up. The extension's own side (the path monitor, the rejoin
// of a runtime, the data-path probes) needs a device and is integration-only.

final class VPNSessionRecoveryTests: XCTestCase {

    func testTheFirstPathIsOnlyTheBaseline() {
        var recovery = VPNSessionRecovery()
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
        XCTAssertFalse(recovery.offline)
    }

    func testALossHoldsOnceAndItsReturnRejoins() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertTrue(recovery.offline)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .none, "already holding")
        // Back on the same Wi-Fi: the rooms' paths went with the gap all the same.
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .rejoin)
        XCTAssertFalse(recovery.offline)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .none)
    }

    func testAnotherNetworkTakingOverRejoins() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .none)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .wifi), .rejoin)
    }

    func testANetworkGoneRightAfterTheStartHoldsAtOnce() {
        var recovery = VPNSessionRecovery()
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
    }

    func testFailuresBackOffAndTheTunnelIsGivenUpAfterTheLastTry() {
        var recovery = VPNSessionRecovery()
        var delays: [TimeInterval] = []
        while let delay = recovery.afterFailure(random: 0) { delays.append(delay) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 60])
        XCTAssertEqual(recovery.attempts, VPNSessionRecovery.maxAttempts)
        XCTAssertNil(recovery.afterFailure(random: 0), "spent tries stay spent")
    }

    func testACarryingProbeOrANewNetworkGivesTheTriesBack() {
        var recovery = VPNSessionRecovery()
        _ = recovery.pathChanged(satisfied: true, primary: .wifi)
        _ = recovery.afterFailure(random: 0)
        _ = recovery.afterFailure(random: 0)
        recovery.carried()
        XCTAssertEqual(recovery.afterFailure(random: 0), 2)

        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.attempts, 0)

        _ = recovery.afterFailure(random: 0)
        XCTAssertEqual(recovery.pathChanged(satisfied: false, primary: nil), .hold)
        XCTAssertEqual(recovery.pathChanged(satisfied: true, primary: .cellular), .rejoin)
        XCTAssertEqual(recovery.attempts, 0)
    }

    func testTheJitterTakesUpToAQuarter() {
        XCTAssertEqual(VPNSessionRecovery.delay(attempt: 0, random: 1), 1.5)
        XCTAssertEqual(VPNSessionRecovery.delay(attempt: 5, random: 1), 45)
        XCTAssertEqual(VPNSessionRecovery.delay(attempt: 9, random: 0.5), 52.5)
        XCTAssertEqual(VPNSessionRecovery.delay(attempt: -3, random: 7), 1.5, "inputs are clamped")
    }

    func testARejoinIsProbedSoonerThanAStart() {
        XCTAssertLessThan(VPNSessionRecovery.rejoinGrace, VPNDataPathHealth.startupGrace)
        XCTAssertLessThan(VPNSessionRecovery.settleDelay, VPNSessionRecovery.rejoinGrace)
    }
}
