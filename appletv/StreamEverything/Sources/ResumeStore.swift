import Foundation

/// Where playback stopped for each title, kept on disk so Resume survives restarts.
final class ResumeStore: ObservableObject {
    struct Mark: Codable, Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let poster: String
        let kind: Kind
        /// Enough to rebuild the play request later.
        let entryId: Int
        let episodeId: Int
        let season: Int
        let episode: Int
        var positionMs: Int
        var durationMs: Int
        var updatedAt: Double
        /// File extension of the episode, so the on-disk copy can be found again.
        var ext: String? = nil

        var fraction: Double { durationMs > 0 ? Double(positionMs) / Double(durationMs) : 0 }
        var finished: Bool { fraction > 0.97 }
    }

    @Published private(set) var marks: [String: Mark] = [:]
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("resume.json")
        if let data = Persist.load(key: "resume", file: file),
           let saved = try? JSONDecoder().decode([String: Mark].self, from: data) {
            marks = saved
        }
    }

    static func movieKey(_ id: Int) -> String { "movie:\(id)" }
    static func episodeKey(_ id: Int) -> String { "ep:\(id)" }
    static func seriesKey(_ id: Int) -> String { "series:\(id)" }

    func mark(for key: String) -> Mark? { marks[key] }

    /// The last episode played for a series, to pick up where the viewer left off.
    func lastEpisode(seriesId: Int) -> Mark? {
        marks.values.filter { $0.kind == .series && $0.entryId == seriesId }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func remember(_ mark: Mark) {
        var updated = mark
        updated.updatedAt = Date().timeIntervalSince1970
        marks[mark.key] = updated
        persist()
    }

    /// Carry a position from one copy of a title to another (a source switch) when the
    /// two run the same length within `tolerance`, or the new copy's length is unknown.
    /// A newer mark on the target wins.
    func carry(_ source: Mark, toKey key: String, entryId: Int, episodeId: Int, targetDurationMs: Int, ext: String?) {
        guard source.positionMs > 0 else { return }
        if let existing = marks[key], existing.updatedAt >= source.updatedAt { return }
        let known = targetDurationMs > 0 && source.durationMs > 0
        guard !known || abs(targetDurationMs - source.durationMs) <= Self.carryToleranceMs else { return }
        var mark = source
        mark = Mark(key: key, title: source.title, poster: source.poster, kind: source.kind,
                    entryId: entryId, episodeId: episodeId, season: source.season, episode: source.episode,
                    positionMs: source.positionMs, durationMs: source.durationMs, updatedAt: source.updatedAt, ext: ext)
        marks[key] = mark
        persist()
    }

    /// Two copies within three minutes of each other are the same cut.
    static let carryToleranceMs = 3 * 60 * 1000

    func update(key: String, positionMs: Int, durationMs: Int) {
        guard var mark = marks[key] else { return }
        mark.positionMs = positionMs
        if durationMs > 0 { mark.durationMs = durationMs }
        mark.updatedAt = Date().timeIntervalSince1970
        marks[key] = mark
        persist()
    }

    /// Drop one item from history (Continue Playing's "Remove"). For a series mark every
    /// episode of that series goes, otherwise the next episode would pop straight back.
    func remove(_ mark: Mark) {
        // Every copy of the title goes (other sources of the same film or show), and
        // for a series every episode, otherwise the next one would pop straight back.
        let title = Self.titleKey(mark)
        marks = marks.filter { Self.titleKey($0.value) != title }
        persist()
    }

    /// Copies of one title from different sources share this key: the clean title,
    /// without the episode part for a series ("Show · S1 E4").
    static func titleKey(_ mark: Mark) -> String {
        let base = mark.kind == .series ? (mark.title.components(separatedBy: " · ").first ?? mark.title) : mark.title
        return "\(mark.kind):" + base.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Most recent unfinished items, one per title (the latest played copy, whichever
    /// source it came from), for Continue Playing.
    func recent(limit: Int = 20) -> [Mark] {
        var seen = Set<String>()
        var out: [Mark] = []
        for mark in marks.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let title = Self.titleKey(mark)
            if seen.contains(title) { continue }
            seen.insert(title)
            if mark.finished && mark.kind == .movie { continue }
            out.append(mark)
            if out.count >= limit { break }
        }
        return out
    }

    private func persist() {
        // UserDefaults has a small budget on tvOS; keep the newest few hundred marks.
        if marks.count > 400 {
            let keep = marks.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(400)
            marks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
        }
        if let data = try? JSONEncoder().encode(marks) {
            Persist.save(data, key: "resume", file: file)
        }
    }
}
