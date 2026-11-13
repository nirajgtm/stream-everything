import Foundation

/// A live category as the server lists it, before the adult filter runs.
typealias LiveCategoryInfo = ChannelCategory

// MARK: - Network extras: categories, category channels, account limits

extension XtreamClient {
    private static let extraSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    private func extraApiUrl(_ action: String, _ extra: String = "") -> URL {
        URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)&action=\(action)\(extra)")!
    }

    private func extraFetch(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.extraSession.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Xtream", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    /// How many streams this account may run at once; 0 when unknown. It matters
    /// because prefetching the next episode opens a second stream, and a
    /// one-connection account then stutters while you watch.
    func maxConnections() async -> Int {
        guard let data = try? await extraFetch(URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)")!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["user_info"] as? [String: Any] else { return 0 }
        return Lossy.int(info["max_connections"])
    }

    /// Every live category, adult ones included, so `LiveCatalog.markAdultCategories`
    /// can learn which ids to hide. `categories(.live)` already drops them.
    func liveCategoriesIncludingAdult() async throws -> [LiveCategoryInfo] {
        let data = try await extraFetch(extraApiUrl("get_live_categories"))
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.map { ChannelCategory(id: Lossy.string($0["category_id"]), name: Lossy.string($0["category_name"])) }
            .filter { !$0.id.isEmpty }
    }

    /// Channels of one category straight from the server (fresher than the cached
    /// catalog; used by hubs that want the provider's own grouping). Memoized.
    func channelsInCategory(_ categoryId: String) async -> [Entry] {
        if let cached = CatalogMemo.shared.categoryChannels(categoryId) { return cached }
        guard let data = try? await extraFetch(extraApiUrl("get_live_streams", "&category_id=\(categoryId)")),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        for item in items {
            let name = Lossy.string(item["name"])
            let id = Lossy.int(item["stream_id"])
            if name.isEmpty || id == 0 { continue }
            let listedCategory = Lossy.string(item["category_id"])
            out.append(Entry(kind: .live, name: name, id: id, ext: "", logo: Lossy.string(item["stream_icon"]),
                             categoryId: listedCategory.isEmpty ? categoryId : listedCategory))
        }
        CatalogMemo.shared.rememberCategoryChannels(categoryId, out)
        return out
    }
}

/// Per-process memory for things the server answers slowly but that rarely change
/// within a session. Lives outside XtreamClient because an extension cannot add
/// stored properties.
final class CatalogMemo {
    static let shared = CatalogMemo()
    private let lock = NSLock()
    private var categoryChannels: [String: [Entry]] = [:]

    func categoryChannels(_ categoryId: String) -> [Entry]? {
        lock.lock(); defer { lock.unlock() }
        return categoryChannels[categoryId]
    }

    func rememberCategoryChannels(_ categoryId: String, _ channels: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        categoryChannels[categoryId] = channels
    }

    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        categoryChannels = [:]
    }
}

// MARK: - Title index: matching outside titles (TMDB) to catalog entries

/// Finds catalog entries by clean title, and every duplicate of a title across
/// languages and qualities. Built once per catalog list and kept in memory; this
/// replaces the Android app's SQLite mirror.
final class TitleIndex {
    let kind: Kind
    /// The exact list the index was built from; positions in `byKey` point into it.
    let entries: [Entry]
    private let byKey: [String: [Int]]

    init(kind: Kind, entries: [Entry]) {
        self.kind = kind
        self.entries = entries
        var map: [String: [Int]] = [:]
        map.reserveCapacity(entries.count * 2)
        for (position, entry) in entries.enumerated() {
            for key in TitleIndex.titleKeys(entry.name) where !key.isEmpty {
                map[key, default: []].append(position)
            }
        }
        byKey = map
    }

    /// Catalog entry whose title matches `title` (exact after normalization, leading
    /// article optional). Among duplicates, the best quality/original-audio copy wins.
    /// Nil when the catalog has nothing, so outside rails can hide what you cannot play.
    func find(title: String) -> Entry? {
        for key in TitleIndex.titleKeys(title) {
            guard let positions = byKey[key], !positions.isEmpty else { continue }
            return positions.map { entries[$0] }
                .max { TitleIndex.preferenceScore(name: $0.name, ext: $0.ext) < TitleIndex.preferenceScore(name: $1.name, ext: $1.ext) }
        }
        return nil
    }

    /// All entries that are the same title as `name` (every source/quality/language
    /// duplicate), best first. Powers the "Other sources" picker.
    func sources(for name: String) -> [Entry] {
        let key = TitleIndex.titleKey(of: name)
        guard !key.isEmpty, let positions = byKey[key] else { return [] }
        return positions.map { entries[$0] }
            .sorted { TitleIndex.preferenceScore(name: $0.name, ext: $0.ext) > TitleIndex.preferenceScore(name: $1.name, ext: $1.ext) }
    }

    /// Match keys for a name: the body after the last " - " provider prefix with every
    /// trailing short "(....)" group removed, normalized; plus a variant with the
    /// leading article dropped. Hand-rolled (no regex) because it runs on 227k rows.
    static func titleKeys(_ name: String) -> [String] {
        let chars = Array(name)
        // Body after the last " - " (the provider/quality prefix boundary).
        var start = 0
        if let dash = lastDashSeparator(in: chars) { start = dash + 3 }
        var end = chars.count
        // Catalog names carry both a year and a country code, "House of the Dragon
        // (2022) (US)"; stripping only one would leave "2022" in the key and never match
        // a clean title. The 6-char cap keeps a real parenthetical ("(Extended Cut)").
        while true {
            while end > start, chars[end - 1] == " " { end -= 1 }
            guard end > start, chars[end - 1] == ")" else { break }
            guard let open = chars[start..<(end - 1)].lastIndex(of: "("), open > start, end - 1 - open <= 6 else { break }
            end = open
        }
        var keys = [TitleText.searchKey(String(chars[start..<end]))]
        while start < end, chars[start] == " " { start += 1 }
        let head = String(chars[start..<min(start + 4, end)]).lowercased()
        let skip = head.hasPrefix("the ") ? 4 : head.hasPrefix("an ") ? 3 : head.hasPrefix("a ") ? 2 : 0
        if skip > 0 { keys.append(TitleText.searchKey(String(chars[(start + skip)..<end]))) }
        return keys
    }

    /// The primary (article-kept) key for a name.
    static func titleKey(of name: String) -> String { titleKeys(name).first ?? "" }

    /// Position of the last " - " in the name, nil when there is none.
    private static func lastDashSeparator(in chars: [Character]) -> Int? {
        var i = chars.count - 3
        while i >= 0 {
            if chars[i] == " ", chars[i + 1] == "-", chars[i + 2] == " " { return i }
            i -= 1
        }
        return nil
    }

    /// Rank a catalog entry by desirability from the signals present in this catalog:
    /// resolution (4K > 1080 > 720 > SD), HDR/Dolby Vision, an mkv container (usually
    /// higher bitrate than mp4), multi-audio and subtitles, and a big penalty for a
    /// foreign-dub prefix so English/original audio wins. The catalog carries no file
    /// size or bitrate, so those cannot factor in.
    static func isCamRelease(_ upperName: String) -> Bool {
        let tokens = upperName.replacingOccurrences(of: "[^A-Z0-9]+", with: " ", options: .regularExpression).split(separator: " ")
        let cam: Set<Substring> = ["CAM", "HDCAM", "CAMRIP", "TS", "HDTS", "TELESYNC", "TC", "HDTC", "TELECINE", "PRE", "PREDVD", "HALL", "DVDSCR", "SCR", "WP", "WORKPRINT"]
        return tokens.contains { cam.contains($0) }
    }

    static func preferenceScore(name: String, ext: String = "") -> Int {
        let upper = name.uppercased()
        var score = 0
        // Language outranks every quality signal: an English 720p copy beats a 4K dub.
        score -= 2000 * LanguagePreference.rank(name: name)
        // Theatre recordings: watchable the week a film comes out, never the copy to
        // keep once a real release lands.
        if Self.isCamRelease(upper) { score -= 1500 }
        if upper.contains("2160") || upper.contains("4K") || upper.contains("UHD") { score += 400 }
        else if upper.contains("1080") || upper.contains("FHD") { score += 300 }
        else if upper.contains("720") || upper.contains(" HD") { score += 200 }
        else if upper.contains("480") || upper.contains(" SD") { score += 100 }
        if upper.contains("REMUX") { score += 200 }
        if upper.contains("HDR") || upper.contains("DOLBY VISION") || upper.contains(" DV ") { score += 120 }
        if upper.contains("BLURAY") || upper.contains("BLU-RAY") { score += 80 }
        if ext.lowercased() == "mkv" { score += 40 }
        // Among same-language copies, more audio tracks and subtitles count for more
        // than one quality step, so a 1080p MULTI+SUB copy beats a bare 4K one.
        if upper.contains("MULTI") || upper.contains("DUAL") || upper.contains("DOLBY") { score += 150 }
        if upper.contains("SUB") || upper.contains("SUBTITLE") || upper.contains("CC") { score += 100 }
        return score
    }
}

/// Holds the built title indexes and the language list, rebuilt only when a catalog
/// list changes size (the same invalidation tag the Android cache files used).
final class CatalogIndexStore {
    static let shared = CatalogIndexStore()
    private let lock = NSLock()
    private var indexes: [Kind: TitleIndex] = [:]
    private var languages: (total: Int, codes: [String])?

    /// The index for `entries`, built now when none matches. Safe from any thread.
    func index(for kind: Kind, entries: [Entry]) -> TitleIndex {
        lock.lock()
        if let existing = indexes[kind], existing.entries.count == entries.count {
            lock.unlock()
            return existing
        }
        lock.unlock()
        // Build outside the lock so a long build does not stall other readers.
        let built = TitleIndex(kind: kind, entries: entries)
        lock.lock(); defer { lock.unlock() }
        indexes[kind] = built
        return built
    }

    /// Language codes present across the catalogs, most common first, keeping only
    /// codes with at least `minimumCount` titles so the filter row stays short.
    func languages(live: [Entry], movies: [Entry], series: [Entry], minimumCount: Int = 200) -> [String] {
        let total = live.count + movies.count + series.count
        lock.lock()
        if let cached = languages, cached.total == total { lock.unlock(); return cached.codes }
        lock.unlock()
        var counts: [String: Int] = [:]
        for list in [live, movies, series] {
            for entry in list {
                if let code = TitleParser.languageCode(of: entry.name) { counts[code, default: 0] += 1 }
            }
        }
        let codes = counts.filter { $0.value >= minimumCount }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.key }
        lock.lock(); defer { lock.unlock() }
        languages = (total, codes)
        return codes
    }

    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        indexes = [:]
        languages = nil
    }
}

// MARK: - AppState: in-memory catalog queries

extension AppState {
    /// Full-catalog counts for a search, used to show only filters that lead somewhere.
    /// Cross-filtered: kind counts respect the language filter and language counts
    /// respect the kind filter.
    struct Availability {
        let kinds: [Kind: Int]
        let languages: [String: Int]
        /// Matches that carry no language prefix at all.
        let untagged: Int
    }

    /// Language codes present in the catalogs, most common first.
    func languages() -> [String] {
        CatalogIndexStore.shared.languages(live: live, movies: movies, series: series)
    }

    /// Pre-build both title indexes off the main thread before rails query them.
    func warmTitleIndexes() async {
        let movies = self.movies, series = self.series
        await Task.detached(priority: .utility) {
            _ = CatalogIndexStore.shared.index(for: .movie, entries: movies)
            _ = CatalogIndexStore.shared.index(for: .series, entries: series)
        }.value
    }

    private func titleIndex(isSeries: Bool) -> TitleIndex {
        isSeries ? CatalogIndexStore.shared.index(for: .series, entries: series)
                 : CatalogIndexStore.shared.index(for: .movie, entries: movies)
    }

    /// Catalog entry for an outside title (TMDB), or nil when you cannot play it here.
    func findByTitle(_ title: String, isSeries: Bool) -> Entry? {
        let found = titleIndex(isSeries: isSeries).find(title: title)
        if let found, adultFilter, found.adult { return nil }
        return found
    }

    /// Every catalog entry that is the same title as `name` across languages and
    /// qualities, best first. Powers an "Other sources" picker.
    func sourcesFor(name: String, isSeries: Bool) -> [Entry] {
        titleIndex(isSeries: isSeries).sources(for: name).filter { !(adultFilter && $0.adult) }
    }

    /// Catalog entry for a Continue Watching label like "Show Name S02E03".
    func seriesForLabel(_ label: String) -> (series: Entry, position: SeasonEpisode)? {
        guard let split = TitleParser.splitSeriesTitle(label),
              let entry = findByTitle(split.series, isSeries: true) else { return nil }
        return (entry, split.position)
    }

    /// Counts per kind and language for the query; nil when the query is too short.
    func availability(query: String, kind: Kind? = nil, language: String? = nil) -> Availability? {
        let parsed = ParsedQuery(query)
        guard parsed.valid else { return nil }
        var kinds: [Kind: Int] = [:]
        var languages: [String: Int] = [:]
        var untagged = 0
        for (entries, entriesKind) in [(live, Kind.live), (movies, .movie), (series, .series)] {
            for entry in entries where parsed.matches(entry) {
                if adultFilter && entry.adult { continue }
                let code = TitleParser.languageCode(of: entry.name)
                // Titles without a prefix always pass the language filter.
                if language == nil || code == nil || code == language { kinds[entriesKind, default: 0] += 1 }
                if kind == nil || entriesKind == kind {
                    if let code { languages[code, default: 0] += 1 } else { untagged += 1 }
                }
            }
        }
        return Availability(kinds: kinds, languages: languages, untagged: untagged)
    }

    /// Search restricted to a kind and/or language with the Android ranking: titles
    /// containing the query verbatim first, then the meaningful words joined, then
    /// scattered words. Capped so typing stays quick.
    func filteredSearch(_ query: String, kind: Kind?, language: String?, limit: Int = 60) -> [Entry] {
        let parsed = ParsedQuery(query)
        guard parsed.valid else { return [] }
        var ranked: [(Int, Entry)] = []
        for (entries, entriesKind) in [(movies, Kind.movie), (series, .series), (live, .live)] where kind == nil || kind == entriesKind {
            for entry in entries {
                if let language, let code = TitleParser.languageCode(of: entry.name), code != language { continue }
                // The adult check runs last: it is far costlier than the text match.
                guard parsed.matches(entry) else { continue }
                if adultFilter && entry.adult { continue }
                ranked.append((parsed.rank(entry), entry))
                if ranked.count >= limit * 3 { break }
            }
        }
        return Self.order(ranked, limit: limit)
    }

    private static func order(_ ranked: [(Int, Entry)], limit: Int) -> [Entry] {
        ranked
            .sorted { a, b in
                if a.0 != b.0 { return a.0 < b.0 }
                return LanguagePreference.rank(name: a.1.name) < LanguagePreference.rank(name: b.1.name)
            }
            .prefix(limit).map { $0.1 }
    }

    /// Exact hits plus titles within a typo or two, all ordered by how far the typed
    /// phrase is from the title. With spaces gone "the ofice" is inside "knifeofice",
    /// but "theofice" is one edit from "theoffice" and two from "knifeofice", so The
    /// Office still comes first. The approximate pass walks the whole catalog, so it
    /// runs off the main thread on a copy of the lists.
    func fuzzySearch(_ query: String, kind: Kind?, language: String?, limit: Int = 60) async -> [Entry] {
        let exact = filteredSearch(query, kind: kind, language: language, limit: limit)
        let parsed = ParsedQuery(query)
        let phrase = Array(parsed.whole.utf8)
        let allowance = FuzzyMatch.allowance(for: phrase.count)
        guard allowance > 0 else { return exact }
        let lists: [(Kind, [Entry])] = [(.movie, movies), (.series, series), (.live, live)]
        let adultFilter = self.adultFilter
        let known = Set(exact.map(\.id))
        let found: [(Int, Entry)] = await Task.detached(priority: .userInitiated) {
            var previous = [Int](), current = [Int]()
            var hits: [(Int, Entry)] = []
            var close = 0
            for (listKind, entries) in lists where kind == nil || kind == listKind {
                for entry in entries {
                    if known.contains(entry.id) { continue }
                    if let language, let code = TitleParser.languageCode(of: entry.name), code != language { continue }
                    if entry.searchKey.utf8.count + allowance < phrase.count { continue }
                    guard let distance = FuzzyMatch.substringDistance(pattern: phrase, text: entry.searchKey, maxDistance: allowance,
                                                                       previous: &previous, current: &current) else { continue }
                    if adultFilter && entry.adult { continue }
                    hits.append((distance, entry))
                    // Far hits (2 edits) pile up fast on a big catalog; stop only once
                    // the close ones are plentiful, or a series would never be reached.
                    if distance <= 1 { close += 1 }
                    if close >= limit * 2 || hits.count >= limit * 20 { return hits }
                }
            }
            return hits
        }.value
        // Score the exact hits the same way so both lists order together. A hit that
        // contains the whole phrase scores 0; one that only contains the core words is
        // measured against the phrase like everything else.
        var previous = [Int](), current = [Int]()
        let scoredExact: [(Int, Entry)] = exact.map { entry in
            if entry.searchKey.contains(parsed.whole) { return (0, entry) }
            let distance = FuzzyMatch.substringDistance(pattern: phrase, text: entry.searchKey, maxDistance: 99,
                                                        previous: &previous, current: &current) ?? 99
            return (distance, entry)
        }
        return Self.order(scoredExact + found, limit: limit)
    }

    /// Catalog entries for what TMDB suggests from the typed text, in TMDB's order.
    /// Only titles the provider carries, matched with the same year and language
    /// rules as the home rails, so a suggestion is always playable.
    func suggestedEntries(for query: String) async -> [Entry] {
        let items = await tmdb.suggest(query)
        guard !items.isEmpty else { return [] }
        let resolver = CatalogResolver(app: self)
        var seen = Set<Int>()
        return items.compactMap { item in
            guard let entry = resolver.find(item), seen.insert(entry.id).inserted else { return nil }
            return entry
        }
    }
}
