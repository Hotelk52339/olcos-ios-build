import Foundation

// MARK: - Room references of the newer carriers
//
// The core takes a room reference verbatim and validates it itself; these
// helpers accept what people actually paste and turn it into the one shape the
// core expects, so a typo fails in the form rather than on the server.

/// A VK Calls join link. The core accepts exactly
/// `https://vk.ru/call/join/<id>` or `https://vk.com/call/join/<id>` — no
/// query, fragment or port (olcrtc-upstream internal/auth/vkcalls,
/// `canonicalLink`). The VK app copies the link inside a sentence, sometimes
/// with tracking parameters or the mobile host; all of that is dropped here.
enum VKCallLink {
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"(https?://)?(m\.)?vk\.(com|ru)/call/join/[A-Za-z0-9_\-]+"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        var link = String(text[range])
        if !link.lowercased().hasPrefix("http") { link = "https://" + link }
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return nil }
        let base = host.hasPrefix("m.") ? String(host.dropFirst(2)) : host
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, let id = parts.last else { return nil }
        return "https://\(base)/call/join/\(id)"
    }

    /// The join value `calls.start` returns may be the bare call id or a whole
    /// link (the API is not consistent about it); either becomes the one shape
    /// the core accepts: `https://vk.ru/call/join/<id>`. Anything else — empty,
    /// a foreign host, an id with characters VK does not use — is nil, never a
    /// guessed link.
    static func fromJoinValue(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = normalized(text) { return link }
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return "https://vk.ru/call/join/\(text)"
    }
}

/// What a room field accepts, per carrier, in one place for every form that
/// asks for a room (the wizard, Add protocol, Reconfigure, the connection
/// editor): the normalised value the server and the saved connection get,
/// whether it is usable, and the hint under the field.
enum CarrierRoomInput {
    /// "" when the input is not a usable room for this carrier.
    static func normalized(carrier: String, _ raw: String) -> String {
        switch carrier {
        case "telemost":   return TelemostRoomService.normalizedRoomInput(raw)
        case "vkcalls":    return VKCallLink.normalized(raw) ?? ""
        case "salutejazz": return SaluteJazzRoom.normalized(raw) ?? ""
        default:           return raw.components(separatedBy: .whitespacesAndNewlines).joined()
        }
    }

    /// Jitsi accepts an empty room (the server generates one); the others
    /// need one in their own shape.
    static func isValid(carrier: String, _ raw: String) -> Bool {
        carrier == "jitsi" || !normalized(carrier: carrier, raw).isEmpty
    }

    static func hint(carrier: String) -> String {
        switch carrier {
        case "telemost":   return L10n.roomIDTelemostHint.localized() + " " + L10n.roomIDLinkHint.localized()
        case "vkcalls":    return L10n.roomIDVkHint.localized()
        case "salutejazz": return L10n.roomIDSaluteHint.localized()
        case "wbstream":   return L10n.roomIDWbstreamHint.localized()
        default:           return L10n.addFlowJitsiRoomHint.localized()
        }
    }

    static func placeholder(carrier: String) -> String {
        switch carrier {
        case "vkcalls":    return "https://vk.com/call/join/…"
        case "salutejazz": return "abcd12:efgh3456"
        case "jitsi":      return "olc-room"
        default:           return L10n.roomIDPlaceholder.localized()
        }
    }
}

/// A SaluteJazz room reference: `<code>:<password>`, each half 4–16 lowercase
/// letters or digits (olcrtc-upstream internal/auth/salutejazz, `splitRoomRef`).
/// The password half is a credential: it is masked in logs (LogStore).
enum SaluteJazzRoom {
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let halves = text.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2, halves.allSatisfy(isPart) else { return nil }
        return text
    }

    static func isPart(_ s: Substring) -> Bool {
        (4...16).contains(s.count) && s.allSatisfy { ($0.isASCII && $0.isLetter && $0.isLowercase) || $0.isASCII && $0.isNumber }
    }
}
