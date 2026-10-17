import Foundation

// MARK: - RoomRotationRule
//
// How the app replaces a protocol's rooms on its own (Settings → Room
// auto-update). There is one rule per protocol, because the protocols differ in
// why a room should ever change:
//
//   telemost                    a room dies 24 hours after it is made, so the
//                               only question is whether the app renews it
//                               ahead of time: Off or Automatic.
//   vkcalls, salutejazz, jitsi  rooms do not expire; changing one is hygiene
//                               for the days a room has to go, so the choice is
//                               a schedule: Off, Daily or Weekly.
//   wbstream                    closed to regular accounts
//                               (CarrierAvailability), so Off is all it offers.
//
// Everything here is PURE: what each picker offers, what a fresh install starts
// with, and how a stored value its protocol does not offer resolves.
// Tests/RoomRotationTests.swift pins all of it.

enum RoomRotationRule: String, CaseIterable, Identifiable {
    /// The app leaves the protocol's rooms alone.
    case off
    /// Telemost only: renew a room ahead of its 24-hour expiry, at the cheapest
    /// moment (TelemostRenewalPolicy).
    case automatic
    /// Replace a room once it is a day old.
    case daily
    /// Replace a room once it is a week old.
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:       return L10n.roomRotationOff.localized()
        case .automatic: return L10n.roomRotationAutomatic.localized()
        case .daily:     return L10n.roomRotationDaily.localized()
        case .weekly:    return L10n.roomRotationWeekly.localized()
        }
    }

    /// Whether the rule makes the app act at all.
    var isOn: Bool { self != .off }

    /// The room age, in hours, at which a scheduled rule replaces a room; nil
    /// for the rules that are not a schedule.
    var intervalHours: Int? {
        switch self {
        case .daily:           return 24
        case .weekly:          return 168
        case .off, .automatic: return nil
        }
    }

    // MARK: Per protocol

    /// The protocols that have a rule, in the order Settings lists them.
    static let carriers = ["telemost", "vkcalls", "salutejazz", "jitsi", "wbstream"]

    /// What the picker of `carrier` offers, and nothing else. A protocol that
    /// is not listed in `carriers` offers only Off, so it can never act.
    static func allowed(for carrier: String,
                        wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> [RoomRotationRule] {
        switch carrier {
        case "telemost":
            return [.off, .automatic]
        case "vkcalls", "salutejazz", "jitsi":
            return [.off, .daily, .weekly]
        case "wbstream":
            return wbStreamOpen ? [.off, .daily, .weekly] : [.off]
        default:
            return [.off]
        }
    }

    /// What a fresh install starts with. Telemost renews by default — that is
    /// what the app has always done, and a Telemost room dies after 24 hours
    /// whatever anyone wants. Every other protocol's rooms do not expire, so
    /// nothing happens until the user asks.
    static func defaultRule(for carrier: String) -> RoomRotationRule {
        carrier == "telemost" ? .automatic : .off
    }

    /// The rule that applies: `stored` when `carrier` offers it, else the
    /// default. A value that is no longer offered (hand-edited, from another
    /// build, or WB Stream's schedule saved before the service closed)
    /// therefore does nothing.
    static func resolved(_ stored: RoomRotationRule?, for carrier: String,
                         wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> RoomRotationRule {
        guard let stored,
              allowed(for: carrier, wbStreamOpen: wbStreamOpen).contains(stored) else {
            return defaultRule(for: carrier)
        }
        return stored
    }

    /// One resolved rule for every protocol in `carriers`, and no others.
    static func normalized(_ rules: [String: RoomRotationRule],
                           wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> [String: RoomRotationRule] {
        var out: [String: RoomRotationRule] = [:]
        for carrier in carriers {
            out[carrier] = resolved(rules[carrier], for: carrier, wbStreamOpen: wbStreamOpen)
        }
        return out
    }

    /// The rules of a fresh install.
    static var defaults: [String: RoomRotationRule] { normalized([:]) }

    /// The one-line note under a protocol's picker: how its rooms behave.
    static func noteKey(for carrier: String,
                        wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> L10n {
        switch carrier {
        case "telemost":
            return .roomRotationNoteTelemost
        case "wbstream" where !wbStreamOpen:
            return .roomRotationNoteClosed
        default:
            return .roomRotationNoteSteady
        }
    }
}
