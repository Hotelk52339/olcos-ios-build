import XCTest
@testable import olcrtc_ios

// Per-protocol room auto-update.
//
// Three layers, bottom up:
//   * RoomRotationRuleTests        what each protocol offers, its default, and how a
//                                  stored value its protocol does not offer resolves
//   * RoomRotationPolicyTests      the pure decisions: which connections a rule
//                                  covers, the exceptions, due / postpone / force
//   * RoomRotationCoordinatorTests the coordinator's pass, driven through its
//                                  injected environment — no stores, Keychain,
//                                  SSH or live tunnel
//
// INTEGRATION-ONLY (not covered here, by design):
//   * The room creators' network legs (VKCallRoomService, SaluteJazzRoomService)
//     and a real `Provisioner.reconfigure` against a saved server.
//   * The silent account check's network legs (`VKCallRoomService.sessionState`,
//     `WBStreamRoomService.sessionState`) — the verdict mapping each one makes
//     is pinned in VKCallRoomTests / WBStreamRoomTests.

// MARK: - The rule model

final class RoomRotationRuleTests: XCTestCase {

    func testEachProtocolOffersOnlyItsOwnChoices() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "telemost"), [.off, .automatic])
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            XCTAssertEqual(RoomRotationRule.allowed(for: carrier), [.off, .daily, .weekly], carrier)
        }
    }

    func testWBStreamOffersOnlyOffWhileItIsClosed() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "wbstream", wbStreamOpen: false), [.off])
        XCTAssertEqual(RoomRotationRule.allowed(for: "wbstream", wbStreamOpen: true), [.off, .daily, .weekly])
        // The default follows the shipped flag.
        XCTAssertEqual(RoomRotationRule.allowed(for: "wbstream"),
                       RoomRotationRule.allowed(for: "wbstream", wbStreamOpen: CarrierAvailability.wbStreamOpen))
    }

    func testAProtocolOutsideTheRulesCanOnlyBeOff() {
        XCTAssertEqual(RoomRotationRule.allowed(for: "a-future-service"), [.off])
        XCTAssertEqual(RoomRotationRule.defaultRule(for: "a-future-service"), .off)
    }

    func testDefaultsAreTelemostAutomaticAndEverythingElseOff() {
        XCTAssertEqual(RoomRotationRule.defaultRule(for: "telemost"), .automatic)
        for carrier in ["vkcalls", "salutejazz", "jitsi", "wbstream"] {
            XCTAssertEqual(RoomRotationRule.defaultRule(for: carrier), .off, carrier)
        }
        XCTAssertEqual(RoomRotationRule.defaults,
                       ["telemost": .automatic, "vkcalls": .off, "salutejazz": .off,
                        "jitsi": .off, "wbstream": .off])
    }

    func testEveryDefaultIsOneOfItsProtocolsChoices() {
        for carrier in RoomRotationRule.carriers {
            XCTAssertTrue(RoomRotationRule.allowed(for: carrier)
                .contains(RoomRotationRule.defaultRule(for: carrier)), carrier)
        }
    }

    func testAStoredChoiceTheProtocolDoesNotOfferResolvesToItsDefault() {
        XCTAssertEqual(RoomRotationRule.resolved(.daily, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(.weekly, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(.automatic, for: "vkcalls"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(.automatic, for: "jitsi"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(nil, for: "telemost"), .automatic)
        XCTAssertEqual(RoomRotationRule.resolved(nil, for: "salutejazz"), .off)
        // A choice the protocol does offer passes through.
        XCTAssertEqual(RoomRotationRule.resolved(.off, for: "telemost"), .off)
        XCTAssertEqual(RoomRotationRule.resolved(.weekly, for: "jitsi"), .weekly)
    }

    func testWBStreamIsForcedOffWhileClosedWhateverWasStored() {
        let stored: [RoomRotationRule?] = [nil] + RoomRotationRule.allCases.map { Optional($0) }
        for value in stored {
            XCTAssertEqual(RoomRotationRule.resolved(value, for: "wbstream", wbStreamOpen: false), .off)
        }
        XCTAssertEqual(RoomRotationRule.resolved(.weekly, for: "wbstream", wbStreamOpen: true), .weekly)
    }

    func testNormalizedHoldsExactlyTheFiveProtocols() {
        let rules = RoomRotationRule.normalized([
            "telemost": .daily,            // not offered: its default
            "vkcalls": .weekly,
            "jitsi": .daily,
            "wbstream": .weekly,           // closed: off
            "a-future-service": .daily,    // not a protocol with a rule: dropped
        ], wbStreamOpen: false)
        XCTAssertEqual(rules, ["telemost": .automatic, "vkcalls": .weekly, "salutejazz": .off,
                               "jitsi": .daily, "wbstream": .off])
    }

    func testOnlyTheScheduledRulesHaveHours() {
        XCTAssertEqual(RoomRotationRule.daily.intervalHours, 24)
        XCTAssertEqual(RoomRotationRule.weekly.intervalHours, 168)
        XCTAssertNil(RoomRotationRule.off.intervalHours)
        XCTAssertNil(RoomRotationRule.automatic.intervalHours)
    }

    func testOnlyOffMakesTheAppDoNothing() {
        XCTAssertFalse(RoomRotationRule.off.isOn)
        for rule in [RoomRotationRule.automatic, .daily, .weekly] {
            XCTAssertTrue(rule.isOn, rule.rawValue)
        }
    }

    /// The raw values are what UserDefaults holds, so they are a contract.
    func testThePersistedWordsAreStable() {
        XCTAssertEqual(RoomRotationRule.allCases.map(\.rawValue), ["off", "automatic", "daily", "weekly"])
    }

    func testEveryChoiceHasItsOwnTitle() {
        let titles = RoomRotationRule.allCases.map(\.title)
        XCTAssertFalse(titles.contains(""))
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testTheNoteUnderEachPickerDescribesItsProtocol() {
        XCTAssertEqual(RoomRotationRule.noteKey(for: "telemost"), .roomRotationNoteTelemost)
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            XCTAssertEqual(RoomRotationRule.noteKey(for: carrier), .roomRotationNoteSteady, carrier)
        }
        XCTAssertEqual(RoomRotationRule.noteKey(for: "wbstream", wbStreamOpen: false), .roomRotationNoteClosed)
        XCTAssertEqual(RoomRotationRule.noteKey(for: "wbstream", wbStreamOpen: true), .roomRotationNoteSteady)
    }
}

// MARK: - The pure decisions

final class RoomRotationPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func record(carrier: String,
                        bundle: Bool = false,
                        roomID: String = "room",
                        roomCreatedAt: Date? = nil) -> ConnectionRecord {
        var params = OlcrtcConnection(carrier: carrier, transport: "vp8channel",
                                      roomID: roomID, key: "k", clientID: "default")
        params.roomCreatedAt = roomCreatedAt
        if bundle { params.bundleLanes = [OlcrtcLane(carrier: "jitsi", transport: "datachannel", roomID: "j")] }
        return ConnectionRecord(name: carrier, details: .olcrtc(params))
    }

    private func params(of record: ConnectionRecord) -> OlcrtcConnection {
        guard case .olcrtc(let params) = record.details else { fatalError("Fixture must be OlcRTC") }
        return params
    }

    private func server(linking record: ConnectionRecord) -> ServerHost {
        var server = ServerHost(label: "Test host", host: "192.0.2.1")
        server.lastConnectionID = record.id
        return server
    }

    // MARK: Eligibility

    func testEveryProtocolWithARuleIsEligible() {
        for carrier in RoomRotationRule.carriers {
            XCTAssertTrue(RoomRotationPolicy.isEligible(record(carrier: carrier)), carrier)
        }
        XCTAssertFalse(RoomRotationPolicy.isEligible(record(carrier: "a-future-service")))
    }

    func testBundlesAndXrayRecordsAreNotEligible() {
        // A whole-server connection's rooms belong to the protocol records it
        // was derived from — those are what change, never the bundle itself.
        XCTAssertFalse(RoomRotationPolicy.isEligible(record(carrier: "vkcalls", bundle: true)))
        let xray = ConnectionRecord(name: "x",
                                    details: .xray(XrayConnection(host: "h", uuid: "u",
                                                                  sni: "s", publicKey: "k")))
        XCTAssertFalse(RoomRotationPolicy.isEligible(xray))
    }

    // MARK: What a rule covers

    func testAScheduleReachesVKSaluteJazzAndJitsi() {
        for carrier in ["vkcalls", "salutejazz", "jitsi"] {
            let r = record(carrier: carrier)
            XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: []), 24, carrier)
            XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .weekly, exceptions: []), 168, carrier)
            XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: .off, exceptions: []), carrier)
        }
    }

    /// Telemost's Automatic belongs to TelemostRenewalCoordinator, and a
    /// schedule is not on its menu — nothing here ever covers it.
    func testTelemostNeverFollowsASchedule() {
        let r = record(carrier: "telemost")
        for rule in RoomRotationRule.allCases {
            XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: rule, exceptions: []), rule.rawValue)
        }
    }

    func testAnExceptedConnectionHasNoSchedule() {
        let r = record(carrier: "vkcalls")
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: []), 24)
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [r.id]))
        // Another connection's exception is none of this one's business.
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [UUID()]), 24)
    }

    func testWBStreamHasNoScheduleWhileClosedEvenIfOneWasSaved() {
        let r = record(carrier: "wbstream")
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [], wbStreamOpen: false))
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .daily, exceptions: [], wbStreamOpen: true), 24)
        XCTAssertEqual(RoomRotationPolicy.scheduledHours(for: r, rule: .weekly, exceptions: [], wbStreamOpen: true), 168)
    }

    func testBundlesAndXrayNeverHaveASchedule() {
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: record(carrier: "vkcalls", bundle: true),
                                                       rule: .daily, exceptions: []))
        let xray = ConnectionRecord(name: "x",
                                    details: .xray(XrayConnection(host: "h", uuid: "u",
                                                                  sni: "s", publicKey: "k")))
        XCTAssertNil(RoomRotationPolicy.scheduledHours(for: xray, rule: .daily, exceptions: []))
    }

    // MARK: The exceptions list

    func testTheExceptionsListHoldsManagedConnectionsWhoseProtocolIsOn() {
        let vk = record(carrier: "vkcalls")
        let jitsi = record(carrier: "jitsi")
        let telemost = record(carrier: "telemost")
        let wb = record(carrier: "wbstream")
        let imported = record(carrier: "vkcalls")           // no saved server holds it
        let whole = record(carrier: "vkcalls", bundle: true)  // a bundle is never listed
        var saved = server(linking: vk)
        saved.extraConnectionIDs = [jitsi.id, telemost.id, wb.id]
        saved.bundleConnectionID = whole.id

        let on: Set<String> = ["vkcalls", "telemost", "wbstream"]
        let listed = RoomRotationPolicy.exceptionCandidates(
            in: [vk, jitsi, telemost, wb, imported, whole], hosts: [saved], ruleIsOn: { on.contains($0) })
        // jitsi: its rule is off. imported: nobody here manages it. whole: a bundle.
        XCTAssertEqual(listed.map(\.id), [vk.id, telemost.id, wb.id])
    }

    func testNothingIsListedWhileEveryRuleIsOff() {
        let vk = record(carrier: "vkcalls")
        XCTAssertTrue(RoomRotationPolicy.exceptionCandidates(
            in: [vk], hosts: [server(linking: vk)], ruleIsOn: { _ in false }).isEmpty)
    }

    func testAMemberOfSomeoneElsesServerAdministersNothing() {
        let r = record(carrier: "vkcalls")
        var saved = server(linking: r)
        saved.agentOnly = true
        saved.agentRole = "member"
        XCTAssertFalse(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        saved.agentRole = "owner"
        XCTAssertTrue(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        saved.agentOnly = nil
        saved.agentRole = nil
        XCTAssertTrue(RoomRotationPolicy.isManaged(r, hosts: [saved]))
        XCTAssertFalse(RoomRotationPolicy.isManaged(r, hosts: []))
    }

    // MARK: The due decision

    private func decide(created: Date?, hours: Int, busy: Bool = false) -> RoomRotationPolicy.Decision {
        RoomRotationPolicy.decide(roomCreatedAt: created, intervalHours: hours, now: now, tunnelBusy: busy)
    }

    func testAnUnknownAgeIsNeverDue() {
        // A nil stamp is no evidence — the coordinator stamps one and starts
        // the clock; it does not guess the room is old.
        XCTAssertEqual(decide(created: nil, hours: 24), .notDue)
        XCTAssertEqual(decide(created: nil, hours: 24, busy: true), .notDue)
    }

    func testNoIntervalIsNeverDue() {
        XCTAssertEqual(decide(created: Date(timeIntervalSince1970: 0), hours: 0), .notDue)
    }

    func testARoomIsDueExactlyWhenItReachesItsInterval() {
        let daily = now.addingTimeInterval(-day)
        XCTAssertEqual(decide(created: daily, hours: 24), .rotate)
        XCTAssertEqual(decide(created: daily.addingTimeInterval(-1), hours: 24), .rotate)
        XCTAssertEqual(decide(created: daily.addingTimeInterval(1), hours: 24), .notDue)
        // A day-old room is not due on the weekly schedule.
        XCTAssertEqual(decide(created: daily, hours: 168), .notDue)
        XCTAssertEqual(decide(created: now.addingTimeInterval(-7 * day), hours: 168), .rotate)
    }

    func testABusyTunnelPostponesADueRoomButNotOneThatIsNotDue() {
        let due = now.addingTimeInterval(-day)
        XCTAssertEqual(decide(created: due, hours: 24, busy: true), .postpone)
        XCTAssertEqual(decide(created: due.addingTimeInterval(60), hours: 24, busy: true), .notDue)
    }

    func testAPostponedRoomIsForcedOnceItIsSixHoursOverdue() {
        let grace = RoomRotationPolicy.busyGrace
        XCTAssertEqual(grace, 6 * 3600, accuracy: 0)
        func overdue(by seconds: TimeInterval, hours: Int = 24) -> RoomRotationPolicy.Decision {
            decide(created: now.addingTimeInterval(-(TimeInterval(hours) * 3600 + seconds)),
                   hours: hours, busy: true)
        }
        XCTAssertEqual(overdue(by: 0), .postpone)
        XCTAssertEqual(overdue(by: grace - 1), .postpone)
        XCTAssertEqual(overdue(by: grace), .force)
        XCTAssertEqual(overdue(by: grace + 3600), .force)
        // The grace counts from when the room was due, whatever the interval.
        XCTAssertEqual(overdue(by: grace - 1, hours: 168), .postpone)
        XCTAssertEqual(overdue(by: grace, hours: 168), .force)
    }

    func testAQuietTunnelNeverWaits() {
        let longAgo = now.addingTimeInterval(-30 * day)
        XCTAssertEqual(decide(created: longAgo, hours: 24, busy: false), .rotate)
        XCTAssertEqual(decide(created: now.addingTimeInterval(-day), hours: 24, busy: false), .rotate)
    }

    // MARK: The live tunnel

    func testOnlyAMeasuredQuietProxySessionIsIdle() {
        let grace = RoomRotationPolicy.idleGrace
        XCTAssertEqual(grace, TelemostRenewalPolicy.idleGrace, accuracy: 0)
        func busy(observable: Bool, last: Date?) -> Bool {
            RoomRotationPolicy.isTunnelBusy(activityIsObservable: observable, lastActivity: last, now: now)
        }
        XCTAssertTrue(busy(observable: true, last: now.addingTimeInterval(-5)))
        XCTAssertTrue(busy(observable: true, last: now.addingTimeInterval(-(grace - 1))))
        XCTAssertFalse(busy(observable: true, last: now.addingTimeInterval(-grace)))
        XCTAssertFalse(busy(observable: true, last: now.addingTimeInterval(-3600)))
        // No measurement, or traffic the app cannot see (a VPN session, one
        // still connecting), is no evidence of rest.
        XCTAssertTrue(busy(observable: true, last: nil))
        XCTAssertTrue(busy(observable: false, last: now.addingTimeInterval(-3600)))
        XCTAssertTrue(busy(observable: false, last: nil))
    }

    func testALiveSessionRidesItsOwnRecordAndAWholeServerConnectionThatJoinedTheRoom() {
        let vk = record(carrier: "vkcalls", roomID: "https://vk.ru/call/join/AAA")
        let vkParams = params(of: vk)
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: nil, record: vk, params: vkParams))
        XCTAssertTrue(RoomRotationPolicy.isRiding(live: vk, record: vk, params: vkParams))

        let other = record(carrier: "vkcalls", roomID: "https://vk.ru/call/join/BBB")
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: other, record: vk, params: vkParams))

        var bundle = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/r", key: "k", clientID: "default")
        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/AAA")]
        let joined = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        XCTAssertTrue(RoomRotationPolicy.isRiding(live: joined, record: vk, params: vkParams))

        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/BBB")]
        let elsewhere = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        XCTAssertFalse(RoomRotationPolicy.isRiding(live: elsewhere, record: vk, params: vkParams))
    }

    // MARK: The "sign in again" silence window

    func testBlockedUntilTheRetryDelayPasses() {
        let until = now.addingTimeInterval(RoomRotationPolicy.signInRetryDelay)
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: nil, now: now))
        XCTAssertTrue(RoomRotationPolicy.isBlocked(blockedUntil: until, now: now))
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: until, now: until))
        XCTAssertFalse(RoomRotationPolicy.isBlocked(blockedUntil: until,
                                                    now: until.addingTimeInterval(1)))
        XCTAssertEqual(RoomRotationPolicy.signInRetryDelay, 24.0 * 3600.0, accuracy: 0)
    }
}

// MARK: - The coordinator's pass

@MainActor
final class RoomRotationCoordinatorTests: XCTestCase {

    private enum Failure: Error { case unreachable }

    @MainActor
    private final class Fixture {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [ConnectionRecord] = []
        var rules: [String: RoomRotationRule] = [:]
        var exceptions: Set<UUID> = []
        var managed = true
        var hasTarget = true
        var hostIsFree = true
        var engaged: ConnectionRecord?
        var connectedProxy = false
        var activity: Date?
        /// Thrown by the VK creator when set.
        var creationError: Error?
        /// Which creator ran, in order.
        var created: [String] = []
        /// The room each Jitsi creation was asked to stay near.
        var jitsiNear: [String] = []
        var applications: [InstallOptions] = []
        var updates: [ConnectionRecord] = []
        var disconnects = 0
        var connects: [ConnectionRecord] = []
        var claims = 0
        var releases = 0
        /// Overrides the server's confirmation; nil answers with a matching URI.
        var reply: ((InstallOptions) -> String?)?
        let host = ServerHost(label: "Test host", host: "192.0.2.1", lastContainerName: "olcrtc-test")

        static func confirmation(_ options: InstallOptions) -> String {
            "olcrtc://\(options.carrier)?\(options.transport)@\(options.roomID)#test-key"
        }

        @discardableResult
        func add(carrier: String, ageHours: Double?, roomID: String = "old-room") -> ConnectionRecord {
            var params = OlcrtcConnection(carrier: carrier,
                                          transport: CarrierTransportMatrix.defaultTransport(for: carrier),
                                          roomID: roomID, key: "test-key", clientID: "default")
            params.roomCreatedAt = ageHours.map { now.addingTimeInterval(-$0 * 3600) }
            let record = ConnectionRecord(name: "\(carrier) room", details: .olcrtc(params))
            records.append(record)
            return record
        }

        func params(of record: ConnectionRecord) -> OlcrtcConnection {
            guard let current = records.first(where: { $0.id == record.id }),
                  case .olcrtc(let params) = current.details else { fatalError("Fixture record missing") }
            return params
        }

        func makeCoordinator() -> RoomRotationCoordinator {
            RoomRotationCoordinator(environment: .init(
                records: { self.records },
                update: { record in
                    self.updates.append(record)
                    if let index = self.records.firstIndex(where: { $0.id == record.id }) {
                        self.records[index] = record
                    }
                },
                rule: { self.rules[$0] ?? .off },
                exceptions: { self.exceptions },
                isManaged: { _ in self.managed },
                target: { _ in
                    guard self.hasTarget else { return nil }
                    return .init(host: self.host, secret: .password("test-only"), container: "olcrtc-test")
                },
                createVKRoom: {
                    self.created.append("vkcalls")
                    if let error = self.creationError { throw error }
                    return "https://vk.ru/call/join/NEWVK"
                },
                createSaluteRoom: {
                    self.created.append("salutejazz")
                    return "abcd12:efgh3456"
                },
                createJitsiRoom: { current in
                    self.created.append("jitsi")
                    self.jitsiNear.append(current)
                    return "https://meet.example.org/olcrtc-newroom1"
                },
                createWBRoom: {
                    self.created.append("wbstream")
                    return WBStreamRoom(roomID: "new-wb-room", token: "new-wb-token")
                },
                applyRoom: { _, options in
                    self.applications.append(options)
                    if let reply = self.reply { return reply(options) }
                    return Fixture.confirmation(options)
                },
                engagedRecord: { self.engaged },
                isConnectedProxy: { self.connectedProxy },
                lastActivity: { self.activity },
                disconnect: { self.disconnects += 1; self.engaged = nil },
                connect: { self.connects.append($0); self.engaged = $0 },
                now: { self.now },
                claimHost: { _ in
                    self.claims += 1
                    return self.hostIsFree
                },
                releaseHost: { _ in self.releases += 1 },
                // Never ask the real accounts; the check has its own coverage.
                lastAccountCheck: { self.now },
                saveAccountCheck: { _ in }))
        }
    }

    // MARK: Every scheduled protocol

    func testEachScheduledProtocolGetsARoomFromItsOwnCreator() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        let salute = f.add(carrier: "salutejazz", ageHours: 25)
        let jitsi = f.add(carrier: "jitsi", ageHours: 25, roomID: "https://meet.example.org/olcrtc-oldroom1")
        f.rules = ["vkcalls": .daily, "salutejazz": .daily, "jitsi": .daily]

        await f.makeCoordinator().checkNow()

        XCTAssertEqual(f.created, ["vkcalls", "salutejazz", "jitsi"])
        XCTAssertEqual(f.applications.map(\.carrier), ["vkcalls", "salutejazz", "jitsi"])
        XCTAssertEqual(f.applications.map(\.roomID),
                       ["https://vk.ru/call/join/NEWVK", "abcd12:efgh3456",
                        "https://meet.example.org/olcrtc-newroom1"])
        XCTAssertEqual(f.params(of: vk).roomID, "https://vk.ru/call/join/NEWVK")
        XCTAssertEqual(f.params(of: salute).roomID, "abcd12:efgh3456")
        XCTAssertEqual(f.params(of: jitsi).roomID, "https://meet.example.org/olcrtc-newroom1")
        for record in [vk, salute, jitsi] {
            XCTAssertEqual(f.params(of: record).roomCreatedAt, f.now)
        }
        XCTAssertEqual(f.claims, 3)
        XCTAssertEqual(f.releases, 3)
    }

    func testTheJitsiRoomIsMadeOnTheServiceOfTheOldOne() async {
        let f = Fixture()
        f.add(carrier: "jitsi", ageHours: 25, roomID: "https://meet.example.org/olcrtc-oldroom1")
        f.rules = ["jitsi": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.jitsiNear, ["https://meet.example.org/olcrtc-oldroom1"])
    }

    func testTheWeeklyScheduleWaitsForAWeek() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 24 * 7 - 1)
        f.rules = ["vkcalls": .weekly]
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty)
        f.now = f.now.addingTimeInterval(3600)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
    }

    func testTheRuleIsReadAtEveryPass() async {
        let f = Fixture()
        f.add(carrier: "salutejazz", ageHours: 30)
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "Off is the default: nothing runs")
        f.rules = ["salutejazz": .daily]
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["salutejazz"])
    }

    func testARoomThatIsNotDueIsLeftAlone() async {
        let f = Fixture()
        f.add(carrier: "jitsi", ageHours: 23)
        f.rules = ["jitsi": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    // MARK: Who is covered

    func testTelemostIsNeverRotatedHere() async {
        let f = Fixture()
        f.add(carrier: "telemost", ageHours: 30)
        f.rules = ["telemost": .automatic]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    func testAnExceptedConnectionKeepsItsRoom() async {
        let f = Fixture()
        let skipped = f.add(carrier: "vkcalls", ageHours: 25)
        let other = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.exceptions = [skipped.id]
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.params(of: skipped).roomID, "old-room")
        XCTAssertEqual(f.params(of: other).roomID, "https://vk.ru/call/join/NEWVK")
    }

    func testAnExceptedConnectionWithNoAgeIsNotEvenStamped() async {
        let f = Fixture()
        let skipped = f.add(carrier: "vkcalls", ageHours: nil)
        f.rules = ["vkcalls": .daily]
        f.exceptions = [skipped.id]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertNil(f.params(of: skipped).roomCreatedAt)
    }

    func testAConnectionThisPhoneDoesNotManageIsLeftToItsOwner() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.add(carrier: "jitsi", ageHours: nil)
        f.rules = ["vkcalls": .daily, "jitsi": .daily]
        f.managed = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.updates.isEmpty, "not even the quiet age stamp")
        XCTAssertEqual(f.claims, 0)
    }

    func testWBStreamIsNeverRotatedWhileItIsClosed() async throws {
        try XCTSkipIf(CarrierAvailability.wbStreamOpen, "WB Stream is open: its schedule applies")
        let f = Fixture()
        f.add(carrier: "wbstream", ageHours: 200)
        // Even a schedule forced into the environment does nothing.
        f.rules = ["wbstream": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertTrue(f.updates.isEmpty)
    }

    func testWBStreamRotatesAgainOnceItIsOpen() async throws {
        try XCTSkipIf(!CarrierAvailability.wbStreamOpen, "WB Stream is closed: nothing to rotate")
        let f = Fixture()
        let wb = f.add(carrier: "wbstream", ageHours: 200)
        f.rules = ["wbstream": .daily]
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["wbstream"])
        XCTAssertEqual(f.params(of: wb).roomID, "new-wb-room")
        XCTAssertEqual(f.params(of: wb).wbToken, "new-wb-token", "the token travels with the room it made")
        XCTAssertEqual(f.applications.first?.wbToken, "new-wb-token")
    }

    // MARK: Unknown ages, failures, silence

    func testAnUnknownAgeIsStampedQuietlyBeforeTheIntervalApplies() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: nil)
        f.rules = ["vkcalls": .daily]
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.params(of: vk).roomCreatedAt, f.now)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.claims, 0)

        f.now = f.now.addingTimeInterval(24 * 3600)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
    }

    func testAMissingServerSecretSkipsTheRoomWithoutCreatingOne() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.hasTarget = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.claims, 0)
    }

    func testAServerBusyWithSomethingElseDefersTheRotation() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.hostIsFree = false
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
        XCTAssertEqual(f.releases, 0, "a claim that was refused is not released")
    }

    func testAFailedCreationKeepsTheRoomAndReleasesTheServer() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.creationError = Failure.unreachable
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertEqual(f.releases, 1)
    }

    func testAnUnconfirmedApplicationKeepsTheRecordsRoom() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-3600)   // quiet, so the room is not held back
        f.reply = { _ in nil }
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.applications.count, 1)
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertEqual(f.params(of: vk).roomID, "old-room")
        XCTAssertEqual(f.disconnects, 0)
        XCTAssertTrue(f.connects.isEmpty)
    }

    func testASignInFailureSilencesTheConnectionForADay() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.creationError = VKCallRoomError.sessionRejected
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        await coordinator.checkNow()
        XCTAssertEqual(f.created.count, 1, "retrying a refused sign-in every pass is noise")
        f.now = f.now.addingTimeInterval(RoomRotationPolicy.signInRetryDelay + 1)
        await coordinator.checkNow()
        XCTAssertEqual(f.created.count, 2)
    }

    // MARK: The live tunnel

    func testARotatedRoomThatTheLiveTunnelWasOnIsJoinedAgain() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 25)
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-3600)   // quiet for an hour
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects.count, 1)
        XCTAssertEqual(f.connects.first?.id, vk.id)
        if case .olcrtc(let joined)? = f.connects.first?.details {
            XCTAssertEqual(joined.roomID, "https://vk.ru/call/join/NEWVK")
        } else {
            XCTFail("the tunnel was not connected again with the corrected record")
        }
    }

    func testABusyLiveTunnelPostponesTheRoomUntilItIsSixHoursOverdue() async {
        let f = Fixture()
        let vk = f.add(carrier: "vkcalls", ageHours: 24)   // due this very moment
        f.rules = ["vkcalls": .daily]
        f.engaged = vk
        f.connectedProxy = true
        let coordinator = f.makeCoordinator()

        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "due, but the tunnel is in use")

        f.now = f.now.addingTimeInterval(6 * 3600 - 60)
        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertTrue(f.created.isEmpty, "still inside the six hours")

        f.now = f.now.addingTimeInterval(60)
        f.activity = f.now.addingTimeInterval(-5)
        await coordinator.checkNow()
        XCTAssertEqual(f.created, ["vkcalls"], "six hours overdue: it goes regardless")
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects.count, 1)
    }

    func testAVPNSessionCountsAsBusyBecauseItsTrafficCannotBeSeen() async {
        let f = Fixture()
        let jitsi = f.add(carrier: "jitsi", ageHours: 24)
        f.rules = ["jitsi": .daily]
        f.engaged = jitsi
        f.connectedProxy = false
        f.activity = nil
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
    }

    func testATunnelOnAnotherConnectionDoesNotHoldARoomBack() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 25)
        let elsewhere = f.add(carrier: "jitsi", ageHours: 1)
        f.rules = ["vkcalls": .daily]
        f.engaged = elsewhere
        f.connectedProxy = true
        f.activity = f.now          // busy, but not on this room
        await f.makeCoordinator().checkNow()
        XCTAssertEqual(f.created, ["vkcalls"])
        XCTAssertEqual(f.disconnects, 0, "the user's session is not ours to replace")
        XCTAssertTrue(f.connects.isEmpty)
    }

    func testAWholeServerSessionThatJoinedTheRoomHoldsItBack() async {
        let f = Fixture()
        f.add(carrier: "vkcalls", ageHours: 24, roomID: "https://vk.ru/call/join/AAA")
        var bundle = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: "https://meet.example.org/r", key: "test-key", clientID: "default")
        bundle.bundleLanes = [OlcrtcLane(carrier: "vkcalls", transport: "vp8channel",
                                         roomID: "https://vk.ru/call/join/AAA")]
        let whole = ConnectionRecord(name: "Whole server", details: .olcrtc(bundle))
        f.records.append(whole)
        f.rules = ["vkcalls": .daily]
        f.engaged = whole
        f.connectedProxy = true
        f.activity = f.now.addingTimeInterval(-5)
        await f.makeCoordinator().checkNow()
        XCTAssertTrue(f.created.isEmpty)
    }
}
