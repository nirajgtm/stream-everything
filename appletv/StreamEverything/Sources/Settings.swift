import Foundation

/// Global app settings, persisted in UserDefaults so they survive restart.
///
/// Port of the Android `Settings`. The keys are kept byte-for-byte ("liveControls",
/// "adultFilter") so both apps describe the same preference the same way.
@MainActor
final class Settings: ObservableObject {

    static let liveControlsKey = "liveControls"
    static let adultFilterKey = "adultFilter"

    /// Typed by the user to turn the adult filter off. On Android it goes into the search
    /// box; here the Settings screen asks for it when the toggle is switched off. Matched
    /// case-insensitively after trimming, exactly like Android.
    static let unlockPhrase = "i love boobies"
    /// Typed to turn the filter back on; relocking never needs a phrase in Settings, but
    /// a search screen can honour it the same way Android does.
    static let lockPhrase = "i hate boobies"

    private let defaults: UserDefaults

    /// Show the pause/forward/backward controls during Live TV. Off by default because
    /// most live streams cannot seek and the controls just get in the way.
    @Published var liveControls: Bool {
        didSet { defaults.set(liveControls, forKey: Self.liveControlsKey) }
    }

    /// Hide adult titles everywhere. Off by default; no switch in Settings, only the
    /// search phrases flip it.
    /// ISO country codes for the Trending rail, comma-separated in storage; empty
    /// means TMDB's global feed. Several codes are mixed into one rail.
    @Published var trendingRegion: String {
        didSet { defaults.set(trendingRegion, forKey: "trendingRegion") }
    }
    var trendingRegionCodes: [String] { trendingRegion.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    func toggleTrendingRegion(_ code: String) {
        if code.isEmpty { trendingRegion = ""; return }
        var codes = trendingRegionCodes
        if let i = codes.firstIndex(of: code) { codes.remove(at: i) } else { codes.append(code) }
        trendingRegion = codes.joined(separator: ",")
    }
    static let trendingRegions: [(code: String, label: String)] = [
        ("", "Global"), ("IN", "India"), ("NP", "Nepal"), ("US", "United States"), ("GB", "United Kingdom"), ("KR", "Korea"), ("JP", "Japan")
    ]

    @Published var adultFilter: Bool {
        didSet { defaults.set(adultFilter, forKey: Self.adultFilterKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // bool(forKey:) returns false for a missing key, which is the right default for
        // liveControls but the wrong one for adultFilter, so that one checks presence first.
        liveControls = defaults.bool(forKey: Self.liveControlsKey)
        trendingRegion = defaults.string(forKey: "trendingRegion") ?? ""
        adultFilter = defaults.bool(forKey: Self.adultFilterKey)   // off unless switched on
    }

    static func matchesUnlockPhrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == unlockPhrase
    }

    static func matchesLockPhrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lockPhrase
    }

    /// Turn the filter off when `phrase` is the unlock phrase. Returns whether it was.
    @discardableResult
    func unlockAdultFilter(with phrase: String) -> Bool {
        guard Self.matchesUnlockPhrase(phrase) else { return false }
        adultFilter = false
        return true
    }

    /// Turn the filter back on. Never needs a phrase: hiding content is always allowed.
    func lockAdultFilter() {
        adultFilter = true
    }
}
