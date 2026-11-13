import Foundation
import SwiftUI

/// What the viewer does in Live TV, kept as JSON in Application Support so the
/// screens open where they were left: favorite channels, the last channel played,
/// which lists were opened recently (they rise to the top of the navigator), which
/// languages were watched (they become home tiles), and per-channel play counts
/// (most-played channels sort first). Mirrors the live half of the Android ResumeStore.
@MainActor
final class LiveMemory: ObservableObject {
    static let shared = LiveMemory()

    private struct Saved: Codable {
        /// Favorited channel ids in the order they were added.
        var favorites: [Int] = []
        /// Navigator key ("favorites", "lang:Hindi", "smart:PPV") -> last opened, epoch seconds.
        var navAccess: [String: Double] = [:]
        /// Language bucket -> last watched, epoch seconds. Drives the home rail tiles.
        var liveLanguages: [String: Double] = [:]
        /// Channel id -> bounded play count.
        var playCounts: [Int: Int] = [:]
        /// Last channel played, so the browse screen can land on it again.
        var lastChannelId: Int?
        /// Channels taken off every list; they live in the Removed list until restored.
        var removed: [Int] = []
    }

    @Published private(set) var favorites: [Int] = []
    @Published private(set) var lastChannelId: Int?
    @Published private(set) var navAccess: [String: Double] = [:]
    @Published private(set) var liveLanguages: [String: Double] = [:]
    @Published private(set) var playCounts: [Int: Int] = [:]
    @Published private(set) var removed: [Int] = []

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("live.json")
        if let data = Persist.load(key: "live", file: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            favorites = saved.favorites
            navAccess = saved.navAccess
            liveLanguages = saved.liveLanguages
            playCounts = saved.playCounts
            lastChannelId = saved.lastChannelId
            removed = saved.removed
        }
    }

    // MARK: Removed channels

    func isRemoved(_ channelId: Int) -> Bool { removed.contains(channelId) }

    var removedSet: Set<Int> { Set(removed) }

    /// Takes a channel off the lists, or puts it back. Returns true when now removed.
    @discardableResult
    func toggleRemoved(_ channelId: Int) -> Bool {
        let nowRemoved: Bool
        if let index = removed.firstIndex(of: channelId) {
            removed.remove(at: index)
            nowRemoved = false
        } else {
            removed.append(channelId)
            nowRemoved = true
        }
        persist()
        return nowRemoved
    }

    // MARK: Favorites

    func isFavorite(_ channelId: Int) -> Bool { favorites.contains(channelId) }

    var favoriteSet: Set<Int> { Set(favorites) }

    /// Flips a channel's favorite state and returns the new state.
    @discardableResult
    func toggleFavorite(_ channelId: Int) -> Bool {
        let nowFavorite: Bool
        if let index = favorites.firstIndex(of: channelId) {
            favorites.remove(at: index)
            nowFavorite = false
        } else {
            favorites.append(channelId)
            nowFavorite = true
        }
        persist()
        return nowFavorite
    }

    // MARK: Navigator usage

    /// Opening a list (an explicit click) marks it recently accessed.
    func touchNav(_ key: String) {
        navAccess[key] = Date().timeIntervalSince1970
        persist()
    }

    // MARK: Watched languages (home tiles)

    /// Records that a channel of `language` was watched. "Other" is not a language
    /// anyone wants as a tile, so it is skipped.
    func touchLanguage(_ language: String) {
        guard !language.isEmpty, language != "Other" else { return }
        liveLanguages[language] = Date().timeIntervalSince1970
        persist()
    }

    /// Languages watched, most recent first.
    func recentLanguages(limit: Int = 12) -> [String] {
        liveLanguages.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Hides a language tile from the home rail; it comes back once replayed.
    func removeLanguage(_ language: String) {
        guard liveLanguages.removeValue(forKey: language) != nil else { return }
        persist()
    }

    // MARK: Plays

    /// Counts a play with diminishing returns: full credit to 100, then about 1 per
    /// 10 plays, then about 1 per 100, so one channel's count stays bounded but the
    /// ordering among channels is preserved.
    func recordPlay(_ channelId: Int) {
        let count = playCounts[channelId] ?? 0
        let increment: Int
        if count < 100 { increment = 1 }
        else if count < 300 { increment = Int.random(in: 0..<10) == 0 ? 1 : 0 }
        else { increment = Int.random(in: 0..<100) == 0 ? 1 : 0 }
        if increment > 0 { playCounts[channelId] = count + increment }
        lastChannelId = channelId
        persist()
    }

    func playCount(_ channelId: Int) -> Int { playCounts[channelId] ?? 0 }

    /// Most-played first, keeping the incoming order among equals (stable sort).
    func sortedByPlays(_ channels: [Entry]) -> [Entry] {
        let counts = playCounts
        return channels.enumerated()
            .sorted { lhs, rhs in
                let l = counts[lhs.element.id] ?? 0, r = counts[rhs.element.id] ?? 0
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Persistence

    private func persist() {
        let saved = Saved(favorites: favorites, navAccess: navAccess, liveLanguages: liveLanguages,
                          playCounts: playCounts, lastChannelId: lastChannelId, removed: removed)
        if let data = try? JSONEncoder().encode(saved) {
            Persist.save(data, key: "live", file: file)
        }
    }
}
