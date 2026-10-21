import Foundation
import Network

// MARK: - VPNConfig (#vpn)
//
// The tunnel configuration handed from the main app to the packet-tunnel
// extension. Compiled into BOTH targets (olcrtc-ios and olcrtc-tunnel — the
// extension target lists this file explicitly in project.yml), and carried
// across the process boundary inside
// NETunnelProviderProtocol.providerConfiguration.
//
// providerConfiguration is a plist/JSON dictionary persisted by the system
// into the VPN configuration store, so every value here is limited to
// String / Int / Bool (enforced by the round-trip helpers below). No App
// Group and no keychain sharing is involved in v1 — which also means keyHex
// and wbToken ride the system VPN preferences; an accepted trade-off of the
// minimal-signing-surface decision (vpn-impl-decisions.md).
//
// vp8FPS / vp8Batch mirror OlcrtcConnection's per-connection overrides:
// nil = "let the Go core use its own defaults" (30 / 64, mobile/config.go),
// so the extension never needs SettingsStore. waitReadyTimeoutMs = 0 likewise
// defers to the core's default ready timeout (8 s, mobile/runtime.go).

struct VPNConfig: Codable, Equatable, Sendable {

    /// Loopback SOCKS5 port the core binds INSIDE the extension process.
    /// Fixed and private to the extension — unrelated to proxy mode's port.
    static let defaultSocksPort = 18080

    var carrier:   String        // MobileRuntime.setProvider — jitsi | telemost | wbstream | vkcalls | salutejazz | mtslink | none
    var transport: String        // setTransport — datachannel | vp8channel | seichannel (videochannel is rejected in VPN mode)
    var roomID:    String        // setRoom — room ID or URL, verbatim
    var clientID:  String        // setDeviceID
    var keyHex:    String        // setKey — 64-char hex (32 bytes)
    var dns:       String        // setDNS — "host:port", e.g. "8.8.8.8:53"
    var vp8FPS:    Int?          // setVP8Options (vp8channel only); nil = core default
    var vp8Batch:  Int?          // setVP8Options (vp8channel only); nil = core default
    var seiFPS:    Int           // setSEIOptions (seichannel only)
    var seiBatch:  Int
    var seiFrag:   Int
    var seiACK:    Int
    var wbToken:   String        // setProviderToken — empty for non-wbstream carriers
    var waitReadyTimeoutMs: Int  // Runtime.waitReady; 0 = core default (8 s)
    var socksPort: Int           // in-extension loopback SOCKS port (defaultSocksPort)
    // boc #470: the resolver the OS is handed (NEDNSSettings) — "host:port",
    // same shape as `dns`. They differ in WHERE the query is answered from:
    // `dns` is the core's own resolver, dialled from the PHONE (provider-process
    // sockets bypass the tunnel), while the OS's DNS rides the default route
    // THROUGH the tunnel and is dialled by the olcrtc SERVER. The Russian-
    // carrier presets (AppConstants.ruCarrierDnsPresets, "resolve only from
    // inside the carrier's network") are right for the first and unreachable
    // for the second: MTS + VPN mode reported "Connected" while every hostname
    // on the device failed to resolve. The bridge init substitutes a public
    // resolver here for those; every other choice passes through unchanged.
    var systemDNS: String
    // eoc #470
    // boc xray: which Go core the extension drives. `olcrtc` (default, and what
    // every profile saved before this field existed decodes to) is upstream's
    // `MobileRuntime`; `xray` is olcos-core's VLESS · REALITY engine, configured
    // by the single `xrayLink` (a `vless://` link — the UUID inside it is the
    // credential, so it is a `secretConfigKeys` entry like keyHex/wbToken). The
    // olcrtc-only fields are carried but ignored by the xray path (carrier/
    // transport/roomID double as human-readable labels there).
    var engine:    String
    var xrayLink:  String
    // eoc xray
    /// Settings → Routing: the destinations the extension's core dials itself,
    /// in the core's direct-list syntax; "" for everything through the tunnel.
    var directRules: String
    /// A whole-server connection bonded inside the extension (Settings → VPN
    /// bonding): every lane's carrier, transport and room as JSON, and the
    /// server's bond endpoint "host:port". Empty: one room, as before.
    var lanesJSON: String
    var bond: String

    /// One room of a bonded session, as the extension starts it.
    struct Lane: Codable, Equatable, Sendable {
        var carrier: String
        var transport: String
        var room: String
    }

    /// How many lanes the extension runs at most: each is a WebRTC session in a
    /// process iOS caps at about 50 MB.
    static let maxBondedLanes = 3

    /// The lanes to bond, or [] for one room.
    var lanes: [Lane] {
        guard !bond.isEmpty, let data = lanesJSON.data(using: .utf8),
              let lanes = try? JSONDecoder().decode([Lane].self, from: data), lanes.count > 1 else { return [] }
        return lanes
    }

    var isBonded: Bool { !lanes.isEmpty }

    /// PURE. How long the extension waits before it tries to join a bonded
    /// lane again: 2 s, then twice as long after each try, at most 2 min. Each
    /// try is a whole WebRTC join, so a room that stays broken must not cost
    /// the battery one every few seconds. The same rule as proxy mode's lane
    /// watch (OlcrtcEngine.nextLaneDelay), which the app target's tests hold
    /// it to.
    static func nextLaneDelay(after previous: TimeInterval) -> TimeInterval {
        min(max(previous * 2, 2), 120)
    }

    /// PURE. How long a lane may stay joining before it is ended and started
    /// again: the start's own budget, at least 45 s. The core's first join
    /// can wait forever: a room the server sets up again under it (Jitsi
    /// closes an empty conference) leaves the provider waiting for a peer
    /// that is in the new one. Proxy mode's lane watch uses it too.
    static func laneJoinLimit(timeoutMs: Int) -> TimeInterval {
        max(Double(timeoutMs) / 1_000, 45)
    }

    static let engineOlcrtc = "olcrtc"
    static let engineXray   = "xray"

    var isXray: Bool { engine == Self.engineXray }

    /// The credential this config needs to start — keyHex for olcrtc, the
    /// vless link for xray. `PacketTunnelProvider.startTunnel` fails closed
    /// when it is blank (a profile whose secrets were scrubbed after a session).
    var hasCredentials: Bool { isXray ? !xrayLink.isEmpty : !keyHex.isEmpty }

    /// DNS server host with the port stripped, for NEDNSSettings(servers:).
    /// Handles "8.8.8.8:53", bracketed IPv6 "[2001:db8::1]:53", and a bare
    /// host with no port.
    /// The first resolver the core asks (`dns` may be a list).
    var dnsHost: String { Self.host(of: dns.split(separator: ",").first.map(String.init) ?? dns) }

    /// #470: `systemDNS` with the port stripped — what `NEDNSSettings` takes.
    var systemDNSHost: String { Self.host(of: systemDNS) }

    // boc #484: the packet pump deliberately drops IPv6; never install an IPv6
    // OS resolver, including a profile saved by an older build. Keep the core's
    // `dns` untouched: its provider-owned sockets use the underlying interface.
    // Fail closed rather than silently replacing a user's resolver/privacy policy.
    var supportsPacketDNS: Bool { Self.supportsPacketDNS(systemDNS) }

    static func supportsPacketDNS(_ resolver: String) -> Bool {
        let value = resolver.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "53") else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        // NEDNSSettings requires IP literals and offers no custom port. Reject
        // names too: resolving one could bootstrap via an unsupported IPv6 path.
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil
        }
    }
    // eoc #484

    /// #470: the `dnsHost` rule, factored so both resolvers use it.
    static func host(of dns: String) -> String {
        let raw = dns.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            return String(raw[raw.index(after: raw.startIndex)..<close])
        }
        // A lone colon separates host:port; multiple colons without brackets
        // mean a bare IPv6 host (no port to strip).
        let parts = raw.split(separator: ":")
        if parts.count == 2, let first = parts.first { return String(first) }
        return raw
    }

    // MARK: Construction

    /// #470: `systemDNS` is last so every existing call keeps its argument
    /// order; nil ⇒ the same resolver as `dns`.
    init(carrier: String, transport: String, roomID: String, clientID: String,
         keyHex: String, dns: String, vp8FPS: Int? = nil, vp8Batch: Int? = nil,
         seiFPS: Int = 30, seiBatch: Int = 10, seiFrag: Int = 1200, seiACK: Int = 1,
         wbToken: String = "", waitReadyTimeoutMs: Int = 0,
         socksPort: Int = VPNConfig.defaultSocksPort,
         systemDNS: String? = nil,
         engine: String = VPNConfig.engineOlcrtc, xrayLink: String = "",
         directRules: String = "", lanesJSON: String = "", bond: String = "") {
        self.carrier   = carrier
        self.transport = transport
        self.roomID    = roomID
        self.clientID  = clientID
        self.keyHex    = keyHex
        self.dns       = dns
        self.vp8FPS    = vp8FPS
        self.vp8Batch  = vp8Batch
        self.seiFPS    = seiFPS
        self.seiBatch  = seiBatch
        self.seiFrag   = seiFrag
        self.seiACK    = seiACK
        self.wbToken   = wbToken
        self.waitReadyTimeoutMs = waitReadyTimeoutMs
        self.socksPort = socksPort
        self.systemDNS = systemDNS ?? dns   // #470
        self.engine    = engine
        self.xrayLink  = xrayLink
        self.directRules = directRules
        self.lanesJSON = lanesJSON
        self.bond      = bond
    }

    // App-target-only bridge. OlcrtcConnection is NOT compiled into the
    // olcrtc-tunnel target (it would drag OlcrtcURI → L10n/SettingsStore/
    // LogStore along), so project.yml must add OLCRTC_TUNNEL_EXTENSION to the
    // tunnel target's SWIFT_ACTIVE_COMPILATION_CONDITIONS to exclude this
    // init there. The extension only ever uses init?(providerConfiguration:).
    #if !OLCRTC_TUNNEL_EXTENSION
    /// PURE. The rooms a bonded VPN runs, at most `maxBondedLanes`: one of each
    /// service in turn (the first room first), so three rooms of one service do
    /// not crowd out the others. The video transport cannot fit the extension
    /// (see startTunnel).
    static func bondedLanes(_ lanes: [OlcrtcLane]) -> [OlcrtcLane] {
        let usable = lanes.filter { $0.transport != "videochannel" }
        var services: [String] = []
        var byService: [String: [OlcrtcLane]] = [:]
        for lane in usable {
            if byService[lane.carrier] == nil { services.append(lane.carrier) }
            byService[lane.carrier, default: []].append(lane)
        }
        var picked: [OlcrtcLane] = []
        var round = 0
        while picked.count < maxBondedLanes, picked.count < usable.count {
            for service in services where picked.count < maxBondedLanes {
                if let rooms = byService[service], round < rooms.count { picked.append(rooms[round]) }
            }
            round += 1
        }
        return picked
    }

    /// Builds the extension config from a saved connection. `key`/`wbToken`
    /// must already be restored from ConnectionSecretStore (they are Keychain-
    /// only and never ride OlcrtcConnection's own Codable form).
    ///
    /// `fallbackVP8FPS`/`fallbackVP8Batch` are the app-global values (from
    /// SettingsStore); the per-connection overrides win, matching
    /// OlcrtcEngine's `params.vp8FPS ?? settings.vp8FPS` resolution. Leaving
    /// them nil defers to the Go core's own defaults.
    /// `bonded`: run a whole-server connection's lanes inside the extension
    /// (at most `maxBondedLanes`) instead of its first room only.
    init(from connection: OlcrtcConnection, dns: String, timeoutMs: Int,
         socksPort: Int = VPNConfig.defaultSocksPort,
         fallbackVP8FPS: Int? = nil, fallbackVP8Batch: Int? = nil,
         directRules: String = "", bonded: Bool = false) {
        let lanes = Self.bondedLanes(connection.lanes)
            .map { Lane(carrier: $0.carrier, transport: $0.transport, room: $0.roomID) }
        let bond = bonded && lanes.count > 1 ? (connection.bond ?? "") : ""
        let lanesJSON = bond.isEmpty ? "" : (try? JSONEncoder().encode(lanes)).map { String(decoding: $0, as: UTF8.self) } ?? String()
        // A session with an MTS Link room runs at least 60 / 64 (Vp8Tuning); the
        // extension applies the one pair to every lane it starts.
        var tunedFPS = connection.vp8FPS ?? fallbackVP8FPS
        var tunedBatch = connection.vp8BatchSize ?? fallbackVP8Batch
        let sessionCarriers = bond.isEmpty ? [connection.carrier] : lanes.map(\.carrier)
        if sessionCarriers.contains("mtslink") {
            let tuned = Vp8Tuning.effective(carriers: sessionCarriers,
                                            fps: tunedFPS ?? SettingsStore.Defaults.vp8FPS,
                                            batch: tunedBatch ?? SettingsStore.Defaults.vp8BatchSize)
            tunedFPS = tuned.fps
            tunedBatch = tuned.batch
        }
        self.init(
            carrier:   connection.carrier,
            transport: connection.transport,
            roomID:    connection.roomID,
            clientID:  connection.clientID,
            keyHex:    connection.key,
            dns:       DNSChoice.forPhoneCore(dns),
            vp8FPS:    tunedFPS,
            vp8Batch:  tunedBatch,
            seiFPS:    connection.seiFPS,
            seiBatch:  connection.seiBatch,
            seiFrag:   connection.seiFrag,
            seiACK:    connection.seiACK,
            wbToken:   connection.wbToken,
            waitReadyTimeoutMs: timeoutMs,
            socksPort: socksPort,
            systemDNS: Self.systemResolver(for: dns),   // #470
            directRules: directRules,
            lanesJSON: lanesJSON,
            bond: lanesJSON.isEmpty ? "" : bond)
    }

    /// Builds the extension config for a VLESS · REALITY connection. `uuid` must
    /// already be restored from ConnectionSecretStore (same rule as `key`).
    /// The link is the whole configuration: the extension hands it to
    /// olcos-core's `engine.start` verbatim, so app and appex share one parser.
    init(from connection: XrayConnection, dns: String, timeoutMs: Int,
         socksPort: Int = VPNConfig.defaultSocksPort, directRules: String = "") {
        self.init(
            carrier:   VPNConfig.engineXray,
            transport: "vless-reality",
            roomID:    "\(connection.host):\(connection.port)",
            clientID:  "",
            keyHex:    "",
            dns:       dns,
            waitReadyTimeoutMs: timeoutMs,
            socksPort: socksPort,
            systemDNS: Self.systemResolver(for: dns),
            engine:    VPNConfig.engineXray,
            xrayLink:  XrayURI.encode(connection),
            directRules: directRules)
    }

    /// #470: the resolver the OS may use THROUGH the tunnel. A carrier-internal
    /// preset (answerable only from inside that carrier's network) cannot be
    /// reached from the VPS the tunnel exits at, so it becomes the app's
    /// default public resolver; anything else is the user's own choice and
    /// stays. Compared by host, so a hand-typed preset without a port matches.
    static func systemResolver(for dns: String) -> String {
        DNSChoice.forServer(dns)
    }
    #endif

    // MARK: providerConfiguration round-trip

    /// One shared key set for Codable AND the providerConfiguration dict, so
    /// the two serialisations can never drift.
    private enum CodingKeys: String, CodingKey {
        case carrier, transport, roomID, clientID, keyHex, dns
        case vp8FPS, vp8Batch
        case seiFPS, seiBatch, seiFrag, seiACK
        case wbToken, waitReadyTimeoutMs, socksPort
        case systemDNS   // #470
        case engine, xrayLink
        case directRules
        case lanesJSON, bond
    }

    /// Plist/JSON-safe dictionary for NETunnelProviderProtocol
    /// .providerConfiguration. Values are String/Int only; nil vp8 overrides
    /// are omitted entirely (absence = core default).
    /// #470: the two `providerConfiguration` entries that carry a secret. The
    /// app blanks them in the SAVED profile once a session ends (VPNController),
    /// so the room key and the WB token do not sit in the system's VPN
    /// preferences between sessions; `start()` writes them again every launch.
    static let secretConfigKeys: [String] = [CodingKeys.keyHex.rawValue,
                                             CodingKeys.wbToken.rawValue,
                                             CodingKeys.xrayLink.rawValue]

    func providerConfiguration() -> [String: Any] {
        var dict: [String: Any] = [
            CodingKeys.carrier.rawValue:   carrier,
            CodingKeys.transport.rawValue: transport,
            CodingKeys.roomID.rawValue:    roomID,
            CodingKeys.clientID.rawValue:  clientID,
            CodingKeys.keyHex.rawValue:    keyHex,
            CodingKeys.dns.rawValue:       dns,
            CodingKeys.seiFPS.rawValue:    seiFPS,
            CodingKeys.seiBatch.rawValue:  seiBatch,
            CodingKeys.seiFrag.rawValue:   seiFrag,
            CodingKeys.seiACK.rawValue:    seiACK,
            CodingKeys.wbToken.rawValue:   wbToken,
            CodingKeys.waitReadyTimeoutMs.rawValue: waitReadyTimeoutMs,
            CodingKeys.socksPort.rawValue: socksPort,
            CodingKeys.systemDNS.rawValue: systemDNS,   // #470
            CodingKeys.engine.rawValue:    engine,
            CodingKeys.xrayLink.rawValue:  xrayLink,
            CodingKeys.directRules.rawValue: directRules,
            CodingKeys.lanesJSON.rawValue: lanesJSON,
            CodingKeys.bond.rawValue:      bond,
        ]
        if let vp8FPS   { dict[CodingKeys.vp8FPS.rawValue]   = vp8FPS }
        if let vp8Batch { dict[CodingKeys.vp8Batch.rawValue] = vp8Batch }
        return dict
    }

    /// Rebuilds the config in the extension process. Returns nil when any
    /// required field is missing or mistyped (the provider then fails
    /// startTunnel with .configurationInvalid). Numeric values come back from
    /// the system as NSNumber; `as? Int` bridges them.
    init?(providerConfiguration dict: [String: Any]) {
        guard
            let carrier   = dict[CodingKeys.carrier.rawValue]   as? String,
            let transport = dict[CodingKeys.transport.rawValue] as? String,
            let roomID    = dict[CodingKeys.roomID.rawValue]    as? String,
            let clientID  = dict[CodingKeys.clientID.rawValue]  as? String,
            let keyHex    = dict[CodingKeys.keyHex.rawValue]    as? String,
            let dns       = dict[CodingKeys.dns.rawValue]       as? String
        else { return nil }
        self.init(
            carrier:   carrier,
            transport: transport,
            roomID:    roomID,
            clientID:  clientID,
            keyHex:    keyHex,
            dns:       dns,
            vp8FPS:    dict[CodingKeys.vp8FPS.rawValue]   as? Int,
            vp8Batch:  dict[CodingKeys.vp8Batch.rawValue] as? Int,
            seiFPS:    dict[CodingKeys.seiFPS.rawValue]   as? Int ?? 30,
            seiBatch:  dict[CodingKeys.seiBatch.rawValue] as? Int ?? 10,
            seiFrag:   dict[CodingKeys.seiFrag.rawValue]  as? Int ?? 1200,
            seiACK:    dict[CodingKeys.seiACK.rawValue]   as? Int ?? 1,
            wbToken:   dict[CodingKeys.wbToken.rawValue]  as? String ?? "",
            waitReadyTimeoutMs: dict[CodingKeys.waitReadyTimeoutMs.rawValue] as? Int ?? 0,
            socksPort: dict[CodingKeys.socksPort.rawValue] as? Int ?? VPNConfig.defaultSocksPort,
            // #470: absent in a profile saved by an older build ⇒ same as `dns`.
            systemDNS: dict[CodingKeys.systemDNS.rawValue] as? String,
            // Absent in a profile saved before the xray engine existed ⇒ olcrtc.
            engine:    dict[CodingKeys.engine.rawValue]    as? String ?? VPNConfig.engineOlcrtc,
            xrayLink:  dict[CodingKeys.xrayLink.rawValue]  as? String ?? "",
            // Absent in a profile saved before routing existed ⇒ all through the tunnel.
            directRules: dict[CodingKeys.directRules.rawValue] as? String ?? "",
            // Absent before VPN bonding existed ⇒ one room.
            lanesJSON: dict[CodingKeys.lanesJSON.rawValue] as? String ?? "",
            bond:      dict[CodingKeys.bond.rawValue]      as? String ?? "")
    }
}

// boc #484: shared with the extension and app test target without another
// generated-project source entry. Pure policy/wire checks need no live network.
struct VPNDataPathHealth {
    static let interval: TimeInterval = 20
    static let timeout: TimeInterval = 15
    static let startupGrace: TimeInterval = 45
    static let failureLimit = 3
    private(set) var failures = 0

    mutating func record(success: Bool) -> Bool {
        failures = success ? 0 : min(failures + 1, Self.failureLimit)
        return failures >= Self.failureLimit
    }

    // Root NS question: tiny, independent of a third-party HTTP endpoint.
    static func dnsQuery(id: UInt16) -> Data {
        Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
              0, 0, 2, 0, 1])
    }

    static func validDNSResponse(_ data: Data, id: UInt16) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 17, bytes.count <= 4096,
              bytes[0] == UInt8(id >> 8), bytes[1] == UInt8(id & 255),
              bytes[2] & 0x80 != 0, bytes[2] & 0x78 == 0,
              bytes[4] == 0, bytes[5] == 1 else { return false }
        // Even SERVFAIL/REFUSED proves the bidirectional data path; this is a
        // reachability watch, not a claim that every DNS name can be resolved.
        return Array(bytes[12..<17]) == [0, 0, 2, 0, 1]
    }
}
// eoc #484

/// Which lanes of a bonded session have stopped bringing anything in. A lane
/// whose runtime counts as running can have lost its room: the core then
/// reconnects inside it, pausing up to five minutes between rounds, and its
/// state stays "running" all along. Such a lane receives nothing, while a
/// live one gets frames, or the server's probe copies every few seconds
/// while a download runs. Fed the bond client's per-lane received bytes on
/// every look of the lane watch (proxy mode) or the supervisor (extension).
struct LaneSilenceWatch {
    /// How long a lane may receive nothing while the others carry.
    static let limit: TimeInterval = 180
    /// What the other lanes must have received meanwhile: proof that
    /// traffic ran, so the silence is the lane's and not an idle session's.
    static let evidenceBytes: UInt64 = 256 * 1024

    private var lastRx: [UInt64] = []
    private var grewAt: [TimeInterval] = []
    private var totalAtGrowth: [UInt64] = []

    /// The lanes silent past the limit while the others received at least
    /// `evidenceBytes`. A named lane's watch starts over, so it is named at
    /// most once per limit.
    mutating func silentLanes(rx: [UInt64], now: TimeInterval) -> [Int] {
        let total = rx.reduce(0, &+)
        guard lastRx.count == rx.count else {
            lastRx = rx
            grewAt = Array(repeating: now, count: rx.count)
            totalAtGrowth = Array(repeating: total, count: rx.count)
            return []
        }
        var silent: [Int] = []
        for i in rx.indices {
            // Growth, or counters that started over (a new bond client).
            if rx[i] != lastRx[i] || total < totalAtGrowth[i] {
                lastRx[i] = rx[i]
                grewAt[i] = now
                totalAtGrowth[i] = total
            } else if now - grewAt[i] >= Self.limit, total - totalAtGrowth[i] >= Self.evidenceBytes {
                silent.append(i)
                grewAt[i] = now
                totalAtGrowth[i] = total
            }
        }
        return silent
    }

    /// PURE: the received bytes of each lane in the bond client's
    /// `rx:tx,rx:tx,…` (Client.LaneBytes); nil when it is not that.
    static func receivedBytes(_ laneBytes: String) -> [UInt64]? {
        var rx: [UInt64] = []
        for part in laneBytes.split(separator: ",") {
            let pair = part.split(separator: ":")
            guard pair.count == 2, let value = UInt64(pair[0]), UInt64(pair[1]) != nil else { return nil }
            rx.append(value)
        }
        return rx.isEmpty ? nil : rx
    }
}

/// How a VPN session comes back inside the extension when it stops carrying
/// or its network changes, the way proxy mode's reconnect loop does it in the
/// app (TunnelManager.pathDecision, requestReconnect): the rooms are joined
/// again after a capped, jittered backoff, and the tunnel is given up only
/// once every try is spent. With no network nothing is tried and nothing is
/// counted: the session waits for one. Its return, or another network taking
/// over (Wi-Fi to cellular), joins the rooms again at once: their WebRTC paths
/// went with the old network. Mutated on the extension's work queue only.
struct VPNSessionRecovery {
    enum PathAction: Equatable {
        case none
        /// The network is gone: stop probing and counting, show reconnecting.
        case hold
        /// A network is back, or another one took over: join the rooms again.
        case rejoin
    }

    /// Rejoins after the data path failed, before the tunnel is given up
    /// (proxy mode makes as many).
    static let maxAttempts = 6
    /// A network that just changed gets this long to settle (a hand-over
    /// sends several updates) before the rooms are joined again.
    static let settleDelay: TimeInterval = 2
    /// After a rejoin, the first data-path probe waits this long: joining a
    /// room takes seconds, not the start's whole grace.
    static let rejoinGrace: TimeInterval = 15

    private(set) var attempts = 0
    private(set) var offline = false
    private var seenPath = false
    private var lastPrimary: NWInterface.InterfaceType?

    /// What a path update means for the session. The first one while online
    /// is only the baseline.
    mutating func pathChanged(satisfied: Bool, primary: NWInterface.InterfaceType?) -> PathAction {
        let previous = lastPrimary
        let firstPath = !seenPath
        seenPath = true
        lastPrimary = primary
        guard satisfied else {
            defer { offline = true }
            return offline ? .none : .hold
        }
        if offline {
            offline = false
            attempts = 0
            return .rejoin
        }
        guard !firstPath, primary != previous else { return .none }
        attempts = 0
        return .rejoin
    }

    /// The data path failed its probes, or the core ended, with a network
    /// there: the wait before the rooms are joined again, or nil once every
    /// try is spent and the tunnel is to be given up.
    mutating func afterFailure(random: Double = Double.random(in: 0...1)) -> TimeInterval? {
        guard attempts < Self.maxAttempts else { return nil }
        defer { attempts += 1 }
        return Self.delay(attempt: attempts, random: random)
    }

    /// A probe went through: the session carries again.
    mutating func carried() { attempts = 0 }

    /// PURE: 2 s doubling to 60 s, less up to a quarter, so phones that lost
    /// a room together do not all come back to it in the same second.
    static func delay(attempt: Int, random: Double) -> TimeInterval {
        let base = min(2 * pow(2, Double(min(max(attempt, 0), 20))), 60)
        return base * (1 - 0.25 * min(max(random, 0), 1))
    }
}
