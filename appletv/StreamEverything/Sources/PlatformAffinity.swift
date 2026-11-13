import Foundation

/// How much you actually watch each streaming platform, used to order the home
/// rails (Netflix/Hulu/... rise as you use them).
///
/// Scoring is an exponentially time-decayed play count rather than a running
/// counter, which gives the three properties we want:
///
///  - No overflow. Each play adds 1.0 to a Double that is continuously decayed
///    toward zero, so the score settles around plays-per-day / decay instead of
///    growing without bound. It is also hard-clamped.
///  - Adapts to changing taste. A platform you hammered months ago decays away on
///    its own (`halfLifeDays`); what you watch now rises.
///  - Not twitchy. One play is a small nudge against an established score, and
///    reordering needs a clear margin (`reorderMargin`), so the rails do not
///    reshuffle just because of the single most recent thing you played.
final class PlatformAffinity {
    private struct Score: Codable {
        var score: Double
        var updatedAt: Double   // seconds since 1970
    }

    /// A play is worth half as much three weeks later.
    private let halfLifeDays = 21.0
    private var decayPerSecond: Double { log(2.0) / (halfLifeDays * 24 * 60 * 60) }
    /// Hard clamp; normal use stays far below.
    private let maxScore = 10_000.0
    /// Hysteresis: differences below this do not reorder.
    private let reorderMargin = 0.15

    private let file: URL
    private let lock = NSLock()
    private var scoresByPlatform: [Int: Score] = [:]
    private var loaded = false

    /// Keeps its file in Application Support by default so it survives cache purges.
    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.file = dir.appendingPathComponent("platform_affinity.json")
        }
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = Persist.load(key: "affinity", file: file),
              let saved = try? JSONDecoder().decode([String: Score].self, from: data) else { return }
        for (key, value) in saved {
            if let platform = Int(key), value.score.isFinite { scoresByPlatform[platform] = value }
        }
    }

    private func save() {
        let keyed = Dictionary(uniqueKeysWithValues: scoresByPlatform.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(keyed) { Persist.save(data, key: "affinity", file: file) }
    }

    /// A stored score decayed forward to `now`, without touching the table.
    private func decayed(_ score: Score, now: Double) -> Double {
        let elapsed = max(0, now - score.updatedAt)
        return score.score * exp(-decayPerSecond * elapsed)
    }

    /// Count one play on a platform (a `TmdbClient.Provider.key`).
    func recordPlay(platformKey: Int, now: Date = Date()) {
        guard platformKey > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let at = now.timeIntervalSince1970
        let current = scoresByPlatform[platformKey] ?? Score(score: 0, updatedAt: at)
        scoresByPlatform[platformKey] = Score(score: min(decayed(current, now: at) + 1.0, maxScore), updatedAt: at)
        save()
    }

    /// Current decayed score per platform (higher = watched more, more recently).
    func scores(now: Date = Date()) -> [Int: Double] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let at = now.timeIntervalSince1970
        return scoresByPlatform.mapValues { decayed($0, now: at) }
    }

    /// `items` reordered by affinity, most watched first. Ties, and differences too
    /// small to be meaningful, keep the original order so the rails stay stable
    /// until a real preference emerges.
    func ordered<T>(_ items: [T], now: Date = Date(), platformKey: (T) -> Int) -> [T] {
        let scores = scores(now: now)
        if scores.isEmpty { return items }
        return items.enumerated().sorted { a, b in
            let bandA = floor((scores[platformKey(a.element)] ?? 0) / reorderMargin)
            let bandB = floor((scores[platformKey(b.element)] ?? 0) / reorderMargin)
            return bandA != bandB ? bandA > bandB : a.offset < b.offset
        }.map { $0.element }
    }
}
