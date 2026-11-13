import Foundation

/// Which catalog copy of a title to open by default when the provider lists the same
/// movie or show several times (languages, qualities, networks).
///
/// Two rules, in order:
///  1. A copy you actually played from becomes the default for that title (saved on
///     disk, keyed by the title's match key), exactly like the Android source override.
///  2. With no saved choice, English wins: a copy whose prefix is "EN", or one with no
///     dub prefix at all, is picked before a dubbed copy, no matter which has the
///     higher resolution. The viewer asked for this explicitly.
final class SourceChoiceStore {
    struct Choice: Codable, Equatable {
        let id: Int
        let name: String
        let ext: String
        /// True when the viewer picked this copy from the Sources row; false when the
        /// app chose it. Only an explicit pick is kept when a better copy appears.
        var explicit: Bool = false
    }

    private let file: URL
    private let lock = NSLock()
    private var choices: [String: Choice] = [:]
    private var loaded = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("source_choices.json")
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        if let data = Persist.load(key: "sources", file: file),
           let saved = try? JSONDecoder().decode([String: Choice].self, from: data) {
            choices = saved
        }
    }

    /// The saved copy for a title, keyed by `TitleIndex.titleKey(of:)` of any of its names.
    func choice(forTitleKey key: String) -> Choice? {
        guard !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return choices[key]
    }

    /// Playing from `entry` makes it the default for its title. `explicit` marks a copy
    /// the viewer picked by hand; an automatic save never downgrades an explicit one.
    func remember(_ entry: Entry, explicit: Bool = false) {
        let key = TitleIndex.titleKey(of: entry.name)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let wasExplicit = choices[key]?.id == entry.id && choices[key]?.explicit == true
        choices[key] = Choice(id: entry.id, name: entry.name, ext: entry.ext, explicit: explicit || wasExplicit)
        if let data = try? JSONEncoder().encode(choices) { Persist.save(data, key: "sources", file: file) }
    }

    /// Among `sources` (best first by language then quality), the copy that beats the
    /// saved one by a clear margin: a proper release where the saved copy was a theatre
    /// recording, or a big quality jump. Nil when the saved copy is still the best.
    func betterThanSaved(among sources: [Entry], savedId: Int) -> Entry? {
        guard let saved = sources.first(where: { $0.id == savedId }) else { return nil }
        let savedScore = TitleIndex.preferenceScore(name: saved.name, ext: saved.ext)
        let savedRank = LanguagePreference.rank(name: saved.name)
        let best = sources
            .filter { LanguagePreference.rank(name: $0.name) <= savedRank }
            .max { TitleIndex.preferenceScore(name: $0.name, ext: $0.ext) < TitleIndex.preferenceScore(name: $1.name, ext: $1.ext) }
        guard let best, best.id != saved.id else { return nil }
        let gain = TitleIndex.preferenceScore(name: best.name, ext: best.ext) - savedScore
        return gain >= 300 ? best : nil
    }

    /// Whether a movie is new enough that better copies keep arriving (cam, then web,
    /// then 4K): released within the last year by the year in its name.
    static func isRecent(_ entry: Entry) -> Bool {
        guard let year = TitleParser.parse(entry.name).year.flatMap(Int.init) else { return false }
        let thisYear = Calendar.current.component(.year, from: Date())
        return year >= thisYear - 1
    }

    // MARK: Picking a default

    /// 0 = English or untagged original, 1 = unknown tag, 2 = another language.
    static func englishRank(_ entry: Entry) -> Int { LanguagePreference.rank(name: entry.name) }

    /// `sources` (already best-quality-first) stably regrouped so English copies lead.
    static func englishFirst(_ sources: [Entry]) -> [Entry] {
        sources.enumerated()
            .sorted { a, b in
                let ra = englishRank(a.element), rb = englishRank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { $0.element }
    }

    /// The copy to open: the saved choice when it is still in `sources`, else the best
    /// English copy, else `fallback` (the entry the viewer clicked).
    func preferred(among sources: [Entry], fallback: Entry) -> Entry {
        if let saved = choice(forTitleKey: TitleIndex.titleKey(of: fallback.name)),
           let match = sources.first(where: { $0.id == saved.id }) {
            // A recent film the app picked on its own moves to a clearly better copy
            // as soon as one shows up; a copy the viewer chose stays (the page shows
            // a hint instead, see `betterThanSaved`).
            if !saved.explicit, Self.isRecent(match), let better = betterThanSaved(among: sources, savedId: match.id) {
                return better
            }
            return match
        }
        return Self.englishFirst(sources).first ?? fallback
    }

    /// For the Sources row: the copy to flag as new and better than an explicit pick.
    func upgradeHint(among sources: [Entry], for fallback: Entry) -> Entry? {
        guard let saved = choice(forTitleKey: TitleIndex.titleKey(of: fallback.name)), saved.explicit,
              let match = sources.first(where: { $0.id == saved.id }), Self.isRecent(match) else { return nil }
        return betterThanSaved(among: sources, savedId: match.id)
    }

    /// Short label for a source pill: "EN  ·  4K" style, built from the readable pills of
    /// the raw name (language, quality, network); the clean title itself is left out
    /// because every source shares it.
    static func pillLabel(_ entry: Entry) -> String {
        let parsed = TitleParser.parse(entry.name)
        let tags = parsed.pills.map { $0.text }.filter { Int($0) == nil }   // drop the year pill
        if !tags.isEmpty { return tags.joined(separator: "  ·  ") }
        let country = TitleParser.trailingCountryCode(of: entry.name)
        if let code = entry.lang { return country.isEmpty ? code : "\(code)  ·  \(country)" }
        return country.isEmpty ? (entry.ext.isEmpty ? "Source" : entry.ext.uppercased()) : country
    }
}
