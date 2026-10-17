import Foundation

// MARK: - CarrierAvailability
//
// Which call services the app can still use. A service that its owner closes
// from outside is switched off in ONE place, here, and every screen and
// background job that would offer it asks this file instead of keeping a
// private opinion — so the UI, the auto-update rules and the account check
// cannot disagree about it.

enum CarrierAvailability {

    /// Whether WB Stream still takes regular accounts.
    ///
    /// It does not, as far as the community can tell. WB has made no statement,
    /// so every point below is a report, and any of it may be temporary:
    ///   - On 2026-10-10 WB closed Stream to accounts that are not its
    ///     employees. A regular account's token is answered `401` with
    ///     "PermissionDenied … user is not an employee"
    ///     (kulikov0/whitelist-bypass, issue #188).
    ///   - Ghostlane's CI dropped WB Stream from its release gate on
    ///     2026-10-11: every join of its own was answered `401`.
    ///   - The site's HTML pages sit behind the wbaas antibot (HTTP 498,
    ///     "Подозрительная активность"), and the page keeps its sign-in token
    ///     in localStorage, not in a cookie — so the in-app sign-in page cannot
    ///     lift one either.
    ///
    /// While this is `false` the app offers no WB Stream sign-in and no
    /// automatic room, keeps WB Stream out of the auto-update rules, and says
    /// why. The manual room id and token fields stay: someone may still hold a
    /// token that works.
    ///
    /// Flip it to `true` when WB reopens, and put the earlier wording back in
    /// the strings that now say "closed": roomIDWbstreamHint, wbTokenFooter,
    /// addFlowWBBody, accountsWBBody and carrierWbstreamDesc.
    static let wbStreamOpen = false

    /// PURE. Whether `carrier` can be offered. Every service but WB Stream is
    /// open; the parameter exists so both states can be tested.
    static func isOpen(_ carrier: String,
                       wbStreamOpen: Bool = CarrierAvailability.wbStreamOpen) -> Bool {
        carrier == "wbstream" ? wbStreamOpen : true
    }
}
