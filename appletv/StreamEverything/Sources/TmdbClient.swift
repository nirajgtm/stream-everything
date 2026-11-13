import Foundation

/// One TMDB title, tagged with the streaming services that carry it.
struct TmdbItem: Identifiable, Hashable {
    let tmdbId: Int
    let title: String
    let year: String
    let posterUrl: String
    let overview: String
    let isSeries: Bool
    let popularity: Double
    var providerIds: Set<Int> = []
    /// ISO 639-1 code of the original language ("ne", "hi", "en"); empty when unknown.
    var originalLanguage: String = ""

    var id: Int { tmdbId }
}

/// TMDB reader for the home page and the title details. Everything on Home is built
/// from today's TRENDING list; each trending title is tagged with the US streaming
/// services that carry it, so a provider rail is literally "what's trending today,
/// on that service." Responses are cached on disk with a TTL to stay under the rate
/// limit and to make a second launch instant.
final class TmdbClient {
    /// A streaming service. `ids` lists every TMDB watch-provider id for the service
    /// (TMDB often splits one service into several). `watchmodeId` is the Watchmode
    /// source id, 0 when unknown, in which case rails keep TMDB ordering.
    struct Provider: Hashable, Identifiable {
        let label: String
        let ids: [Int]
        let watchmodeId: Int

        init(_ label: String, _ ids: [Int], watchmodeId: Int = 0) {
            self.label = label
            self.ids = ids
            self.watchmodeId = watchmodeId
        }

        /// Stable key for persistence (affinity scores, cached hubs).
        var key: Int { ids[0] }
        var id: Int { key }
    }

    /// Providers in rough popularity order.
    static let providers: [Provider] = [
        Provider("Netflix", [8], watchmodeId: 203),
        Provider("Prime Video", [9, 119], watchmodeId: 26),
        Provider("Disney+", [337], watchmodeId: 372),
        Provider("Max", [1899, 384], watchmodeId: 387),
        Provider("Hulu", [15], watchmodeId: 157),
        Provider("Apple TV+", [350], watchmodeId: 371),
        Provider("Peacock", [386, 387], watchmodeId: 388),
        Provider("Paramount+", [531, 2303, 2616], watchmodeId: 444),
        Provider("Starz", [43], watchmodeId: 232),
        Provider("AMC+", [526]),
        Provider("Crunchyroll", [283], watchmodeId: 80),
        Provider("Discovery+", [520]),
        Provider("MGM+", [34], watchmodeId: 108),
        Provider("BritBox", [151], watchmodeId: 419),
        Provider("Tubi", [73], watchmodeId: 296),
        Provider("Pluto TV", [300]),
        Provider("The Roku Channel", [207], watchmodeId: 452),
        Provider("Freevee", [613], watchmodeId: 365),
        Provider("Fubo", [257])
    ]

    static func provider(forKey key: Int) -> Provider? { providers.first { $0.key == key } }

    /// A genre row in a provider hub. `watchmodeId` maps to Watchmode's genre id
    /// (0 = no mapping, keep TMDB order).
    struct Genre: Hashable, Identifiable {
        let label: String
        let movieId: Int?
        let tvId: Int?
        let watchmodeId: Int
        var id: String { label }
    }

    static let genres: [Genre] = [
        Genre(label: "Action", movieId: 28, tvId: 10759, watchmodeId: 1),
        Genre(label: "Comedy", movieId: 35, tvId: 35, watchmodeId: 4),
        Genre(label: "Drama", movieId: 18, tvId: 18, watchmodeId: 7),
        Genre(label: "Sci-Fi & Fantasy", movieId: 878, tvId: 10765, watchmodeId: 40),
        Genre(label: "Thriller", movieId: 53, tvId: nil, watchmodeId: 17),
        Genre(label: "Horror", movieId: 27, tvId: nil, watchmodeId: 11),
        Genre(label: "Romance", movieId: 10749, tvId: nil, watchmodeId: 14),
        Genre(label: "Documentary", movieId: 99, tvId: 99, watchmodeId: 6),
        Genre(label: "Animation", movieId: 16, tvId: 16, watchmodeId: 3),
        Genre(label: "Kids & Family", movieId: 10751, tvId: 10762, watchmodeId: 8)
    ]

    /// Real episode name, overview, still and runtime from TMDB.
    struct EpisodeMeta: Hashable {
        let name: String
        let overview: String
        let still: String
        let runtimeMinutes: Int
    }

    struct CastMember: Hashable, Identifiable {
        let name: String
        let character: String
        let profileUrl: String
        var id: String { name + character }
    }

    /// Image sizes TMDB serves; the right one depends on how big the card draws.
    enum ImageSize {
        case poster, still, headshot, logo, backdrop
        /// Cards are 220pt and the TV renders at 2x, so posters need w500; episode
        /// cards draw about 340pt wide and grow on focus, so stills need w780; the
        /// banner fills a 4K frame, so it takes the original.
        var path: String {
            switch self {
            case .poster: "w500"
            case .still: "w780"
            case .headshot: "w300"
            case .logo: "w300"
            case .backdrop: "original"
            }
        }
    }

    static func imageUrl(_ path: String, size: ImageSize) -> String {
        path.isEmpty ? "" : "https://image.tmdb.org/t/p/\(size.path)\(path)"
    }

    private let key: String
    var configured: Bool { !key.isEmpty }

    private let session: URLSession
    private let cacheDir: URL
    private let timeToLive: TimeInterval = 6 * 60 * 60
    private let trendingPages = 4
    private let providerLookupsAtOnce = 8

    init(key: String = Credentials.tmdbKey) {
        self.key = key
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tmdb", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Fetching with a disk cache

    /// A response body from disk when it is fresher than the TTL, otherwise downloaded
    /// and written back. Query values go through URLComponents so "531|2303" encodes.
    private func cachedGet(_ cacheKey: String, path: String, query: [String: String] = [:]) async throws -> Data {
        let file = cacheDir.appendingPathComponent("tmdb_\(cacheKey).json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < timeToLive,
           let data = try? Data(contentsOf: file), !data.isEmpty {
            return data
        }
        guard configured else { throw NSError(domain: "TMDB", code: 401, userInfo: [NSLocalizedDescriptionKey: "No TMDB key"]) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.themoviedb.org"
        components.path = "/3/\(path)"
        var items = [URLQueryItem(name: "api_key", value: key)]
        for (name, value) in query.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: name, value: value)) }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }
        // A burst of rail queries can trip TMDB's rate limit or a slow network; try a
        // few times, then fall back to a stale copy rather than hand back nothing.
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000) }
            do {
                let (data, response) = try await session.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    try? data.write(to: file, options: .atomic)
                    return data
                }
                lastError = NSError(domain: "TMDB", code: code, userInfo: [NSLocalizedDescriptionKey: "TMDB HTTP \(code)"])
                if code == 404 || code == 401 { break }
            } catch {
                lastError = error
            }
        }
        if let stale = try? Data(contentsOf: file), !stale.isEmpty { return stale }
        NSLog("UI tmdb %@ failed: %@", path, lastError.localizedDescription)
        throw lastError
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func parseResults(_ data: Data) -> [TmdbItem] {
        guard let results = json(data)["results"] as? [[String: Any]] else { return [] }
        var out: [TmdbItem] = []
        for item in results {
            let isSeries = Lossy.string(item["media_type"]) == "tv" || item["first_air_date"] != nil
            var title = Lossy.string(item["title"])
            if title.isEmpty { title = Lossy.string(item["name"]) }
            var date = Lossy.string(item["release_date"])
            if date.isEmpty { date = Lossy.string(item["first_air_date"]) }
            let poster = Lossy.string(item["poster_path"])
            let id = Lossy.int(item["id"])
            if title.trimmingCharacters(in: .whitespaces).isEmpty || poster.isEmpty || id == 0 { continue }
            out.append(TmdbItem(
                tmdbId: id, title: title, year: String(date.prefix(4)),
                posterUrl: Self.imageUrl(poster, size: .poster), overview: Lossy.string(item["overview"]),
                isSeries: isSeries, popularity: Lossy.double(item["popularity"]),
                originalLanguage: Lossy.string(item["original_language"])))
        }
        return out
    }

    // MARK: Trending and provider rails

    /// US streaming services (flatrate/free/ads) that carry a title. Cached per title.
    private func providersForTitle(_ item: TmdbItem) async -> Set<Int> {
        let type = item.isSeries ? "tv" : "movie"
        guard let data = try? await cachedGet("wp_\(type)_\(item.tmdbId)", path: "\(type)/\(item.tmdbId)/watch/providers") else { return [] }
        guard let results = json(data)["results"] as? [String: Any] else { return [] }
        // Services carrying the title in any selected country (US when none chosen):
        // a Hindi film on Netflix India should land on the Netflix rail.
        var ids = Set<Int>()
        for region in (regions.isEmpty ? ["US"] : regions) {
            guard let country = results[region] as? [String: Any] else { continue }
            for bucket in ["flatrate", "free", "ads"] {
                for provider in country[bucket] as? [[String: Any]] ?? [] {
                    let id = Lossy.int(provider["provider_id"])
                    if id != 0 { ids.insert(id) }
                }
            }
        }
        return ids
    }

    /// Today's trending titles, each tagged with the services that carry it. The
    /// per-title provider lookups run a few at a time so one rail does not fire
    /// eighty requests at once.
    /// Trending titles, globally or for one country. TMDB's trending feed is global
    /// only, so a country uses discover on titles produced there, newest and most
    /// popular first, which is what "trending in India" means to a viewer there.
    func trendingWithProviders(region: String = "") async throws -> [TmdbItem] {
        let codes = region.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if codes.count > 1 {
            // Several countries: fetch each and interleave, so the rail alternates
            // between them instead of showing one country's whole list first.
            var lists: [[TmdbItem]] = []
            for code in codes { lists.append((try? await trendingWithProviders(region: code)) ?? []) }
            var mixed: [TmdbItem] = []
            var seen = Set<Int>()
            let longest = lists.map(\.count).max() ?? 0
            for i in 0..<longest {
                for list in lists where i < list.count {
                    if seen.insert(list[i].tmdbId).inserted { mixed.append(list[i]) }
                }
            }
            NSLog("UI trending mix regions=%@ counts=%@ mixed=%d", region, lists.map { "\($0.count)" }.joined(separator: ","), mixed.count)
            return mixed
        }
        var items: [TmdbItem] = []
        if region.isEmpty {
            for page in 1...trendingPages {
                items += parseResults(try await cachedGet("trending_day_\(page)", path: "trending/all/day",
                                                          query: ["language": "en-US", "page": "\(page)"]))
            }
        } else {
            let since = Self.isoDate(daysAgo: 180)
            var seen = Set<Int>()
            for page in 1...2 {
                let movies = await discover("trend_\(region)_movie_\(page)", type: "movie",
                    ["with_origin_country": region, "sort_by": "popularity.desc", "primary_release_date.gte": since, "page": "\(page)"])
                let shows = await discover("trend_\(region)_tv_\(page)", type: "tv",
                    ["with_origin_country": region, "sort_by": "popularity.desc", "first_air_date.gte": since, "page": "\(page)"])
                // Interleave so neither type dominates the rail.
                for pair in zip(movies, shows) { for item in [pair.0, pair.1] where seen.insert(item.tmdbId).inserted { items.append(item) } }
                for item in movies.dropFirst(shows.count) + shows.dropFirst(movies.count) where seen.insert(item.tmdbId).inserted { items.append(item) }
            }
            if items.count < 20 {
                // A small industry (Nepal) has few recent titles; pad with its all-time popular.
                for item in await discover("trend_\(region)_movie_all", type: "movie", ["with_origin_country": region, "sort_by": "popularity.desc"])
                    where seen.insert(item.tmdbId).inserted { items.append(item) }
            }
        }
        var tagged = items
        await withTaskGroup(of: (Int, Set<Int>).self) { group in
            var next = 0
            func enqueue(_ group: inout TaskGroup<(Int, Set<Int>)>) {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await self.providersForTitle(item)) }
            }
            for _ in 0..<min(providerLookupsAtOnce, items.count) { enqueue(&group) }
            for await (index, ids) in group {
                tagged[index].providerIds = ids
                enqueue(&group)
            }
        }
        return tagged
    }

    /// Whether a trending item is available on the given provider.
    func onProvider(_ item: TmdbItem, _ provider: Provider) -> Bool {
        item.providerIds.contains { provider.ids.contains($0) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func today() -> String { Self.dayFormatter.string(from: Date()) }

    /// About four months ago, the window for "recent" padding.
    private func recentCutoff() -> String {
        Self.dayFormatter.string(from: Date().addingTimeInterval(-120 * 24 * 60 * 60))
    }

    static func isoDate(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Countries the provider rails are built for; empty means the US catalog with no
    /// origin filter. Set from the Trending setting so "Popular on Netflix" means
    /// Netflix India when India is selected.
    var regions: [String] = []

    private func discover(_ cacheKey: String, type: String, _ extra: [String: String]) async -> [TmdbItem] {
        guard !regions.isEmpty, !extra.keys.contains("with_origin_country") else {
            return await discoverOnce(cacheKey, type: type, extra, region: "US", originFilter: false)
        }
        // One query per selected country, interleaved like the trending rail.
        var lists: [[TmdbItem]] = []
        for region in regions {
            lists.append(await discoverOnce(cacheKey + "_" + region, type: type, extra, region: region, originFilter: true))
        }
        var mixed: [TmdbItem] = []
        var seen = Set<Int>()
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { if seen.insert(list[i].tmdbId).inserted { mixed.append(list[i]) } }
        }
        // A service with few or no originals from the chosen countries (Disney+, Max,
        // Hulu from Nepal, say) still gets a rail: its US catalog fills in after them.
        if mixed.count < 12 {
            for item in await discoverOnce(cacheKey, type: type, extra, region: "US", originFilter: false)
            where seen.insert(item.tmdbId).inserted { mixed.append(item) }
        }
        return mixed
    }

    private func discoverOnce(_ cacheKey: String, type: String, _ extra: [String: String], region: String, originFilter: Bool) async -> [TmdbItem] {
        var query = extra
        query["watch_region"] = region
        query["language"] = "en-US"
        // Titles made in that country, so an Indian selection shows Indian originals
        // on the service rather than Hollywood available in India.
        if originFilter { query["with_origin_country"] = region }
        guard let data = try? await cachedGet(cacheKey, path: "discover/\(type)", query: query) else { return [] }
        return parseResults(data)
    }

    /// A provider's titles to pad a thin trending rail up to a full row. Recent
    /// releases and airings (last ~4 months) come first so current-season originals
    /// surface; general popularity fills any remainder.
    func popularOn(_ provider: Provider) async -> [TmdbItem] {
        let cutoff = recentCutoff()
        var recent: [TmdbItem] = []
        var general: [TmdbItem] = []
        for id in provider.ids {
            let base = ["sort_by": "popularity.desc", "with_watch_providers": "\(id)", "vote_count.gte": "15"]
            recent += await discover("p\(id)_movie_recent", type: "movie", base.merging(["primary_release_date.gte": cutoff]) { $1 })
            recent += await discover("p\(id)_tv_recent", type: "tv", base.merging(["air_date.gte": cutoff]) { $1 })
            general += await discover("p\(id)_movie", type: "movie", base)
            general += await discover("p\(id)_tv", type: "tv", base)
        }
        recent.sort { $0.popularity > $1.popularity }
        general.sort { $0.popularity > $1.popularity }
        return distinctById(recent + general)
    }

    private func distinctById(_ items: [TmdbItem]) -> [TmdbItem] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.tmdbId).inserted }
    }

    // MARK: Provider hub

    /// Merge one discover query across all of a provider's ids and both media types.
    private func rail(for provider: Provider, suffix: String, movie: [String: String]?, tv: [String: String]?) async -> [TmdbItem] {
        var out: [TmdbItem] = []
        for id in provider.ids {
            if let movie {
                out += await discover("h\(id)_\(suffix)_m", type: "movie", movie.merging(["with_watch_providers": "\(id)"]) { $1 })
            }
            if let tv {
                out += await discover("h\(id)_\(suffix)_t", type: "tv", tv.merging(["with_watch_providers": "\(id)"]) { $1 })
            }
        }
        return distinctById(out.sorted { $0.popularity > $1.popularity })
    }

    func newOn(_ provider: Provider) async -> [TmdbItem] {
        await rail(for: provider, suffix: "new",
                   movie: ["sort_by": "primary_release_date.desc", "primary_release_date.lte": today(), "vote_count.gte": "20"],
                   tv: ["sort_by": "first_air_date.desc", "first_air_date.lte": today(), "vote_count.gte": "20"])
    }

    func popularMovies(_ provider: Provider) async -> [TmdbItem] {
        await rail(for: provider, suffix: "popmov", movie: ["sort_by": "popularity.desc", "vote_count.gte": "15"], tv: nil)
    }

    func popularShows(_ provider: Provider) async -> [TmdbItem] {
        await rail(for: provider, suffix: "poptv", movie: nil, tv: ["sort_by": "popularity.desc", "vote_count.gte": "15"])
    }

    func topRated(_ provider: Provider) async -> [TmdbItem] {
        await rail(for: provider, suffix: "top",
                   movie: ["sort_by": "vote_average.desc", "vote_count.gte": "300"],
                   tv: ["sort_by": "vote_average.desc", "vote_count.gte": "200"])
    }

    func byGenre(_ provider: Provider, _ genre: Genre) async -> [TmdbItem] {
        await rail(for: provider, suffix: "g\(genre.movieId ?? genre.tvId ?? 0)",
                   movie: genre.movieId.map { ["sort_by": "popularity.desc", "with_genres": "\($0)", "vote_count.gte": "15"] },
                   tv: genre.tvId.map { ["sort_by": "popularity.desc", "with_genres": "\($0)", "vote_count.gte": "15"] })
    }

    // MARK: Title search

    /// TMDB's best match for a catalog title, so a details screen can pull cast,
    /// stills and a clean overview even when the Xtream server has no tmdb id. The
    /// year narrows the search when the title carries one; a miss falls back to a
    /// year-less search because providers often tag the wrong release year.
    func match(title: String, year: String? = nil, isSeries: Bool) async -> TmdbItem? {
        let clean = TitleParser.clean(title)
        guard !clean.isEmpty else { return nil }
        if let year, !year.isEmpty, let hit = await search(clean, year: year, isSeries: isSeries).first { return hit }
        return await search(clean, year: nil, isSeries: isSeries).first
    }

    /// Raw search results, popularity order as TMDB returns them.
    /// Titles TMDB thinks you mean while typing. TMDB's search tolerates typos and
    /// partial words, which is what makes suggestions useful before the query is
    /// spelled out. Movies and series together, most popular first.
    func suggest(_ text: String, limit: Int = 12) async -> [TmdbItem] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return [] }
        let cacheKey = "suggest_\(TitleParser.normalizeForSearch(trimmed))"
        guard let data = try? await cachedGet(cacheKey, path: "search/multi",
                                              query: ["query": trimmed, "language": "en-US", "include_adult": "false"]) else { return [] }
        return parseResults(data)
            .filter { !$0.title.isEmpty }
            .sorted { $0.popularity > $1.popularity }
            .prefix(limit).map { $0 }
    }

    func search(_ title: String, year: String? = nil, isSeries: Bool) async -> [TmdbItem] {
        let type = isSeries ? "tv" : "movie"
        var query = ["query": title, "language": "en-US", "include_adult": "false"]
        if let year, !year.isEmpty { query[isSeries ? "first_air_date_year" : "primary_release_year"] = year }
        let cacheKey = "search_\(type)_\(TitleParser.normalizeForSearch(title))_\(year ?? "")"
        guard let data = try? await cachedGet(cacheKey, path: "search/\(type)", query: query) else { return [] }
        // Search results do not carry media_type; stamp the kind we asked for.
        return parseResults(data).map {
            TmdbItem(tmdbId: $0.tmdbId, title: $0.title, year: $0.year, posterUrl: $0.posterUrl,
                     overview: $0.overview, isSeries: isSeries, popularity: $0.popularity)
        }
    }

    // MARK: Cast and episodes

    private func credits(_ tmdbId: Int, isSeries: Bool) async -> [[String: Any]] {
        let type = isSeries ? "tv" : "movie"
        guard let data = try? await cachedGet("credits_\(type)_\(tmdbId)", path: "\(type)/\(tmdbId)/credits",
                                              query: ["language": "en-US"]) else { return [] }
        return json(data)["cast"] as? [[String: Any]] ?? []
    }

    /// Top-billed cast names for a title, comma separated (for the hover preview).
    func castNames(tmdbId: Int, isSeries: Bool) async -> String {
        guard tmdbId != 0 else { return "" }
        return await credits(tmdbId, isSeries: isSeries).prefix(4)
            .map { Lossy.string($0["name"]) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Top cast with headshots, for an Apple TV style cast row.
    /// Overview and poster for a known TMDB id: exact, unlike a title search, which can
    /// land on another film with the same name.
    func details(tmdbId: Int, isSeries: Bool) async -> (overview: String, posterUrl: String, originalLanguage: String, backdropUrl: String)? {
        guard tmdbId != 0 else { return nil }
        let type = isSeries ? "tv" : "movie"
        guard let data = try? await cachedGet("details_\(type)_\(tmdbId)", path: "\(type)/\(tmdbId)", query: ["language": "en-US"]),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (Lossy.string(root["overview"]), Self.imageUrl(Lossy.string(root["poster_path"]), size: .poster),
                Lossy.string(root["original_language"]), Self.imageUrl(Lossy.string(root["backdrop_path"]), size: .backdrop))
    }

    func castWithImages(tmdbId: Int, isSeries: Bool, limit: Int = 12) async -> [CastMember] {
        guard tmdbId != 0 else { return [] }
        return await credits(tmdbId, isSeries: isSeries).prefix(limit).compactMap { member in
            let name = Lossy.string(member["name"])
            guard !name.isEmpty else { return nil }
            return CastMember(name: name, character: Lossy.string(member["character"]),
                              profileUrl: Self.imageUrl(Lossy.string(member["profile_path"]), size: .headshot))
        }
    }

    /// Real episode names, overviews and stills for a season, keyed by episode number.
    func seasonEpisodes(tmdbId: Int, season: Int) async -> [Int: EpisodeMeta] {
        guard tmdbId != 0 else { return [:] }
        guard let data = try? await cachedGet("tv_\(tmdbId)_s\(season)", path: "tv/\(tmdbId)/season/\(season)",
                                              query: ["language": "en-US"]) else { return [:] }
        var out: [Int: EpisodeMeta] = [:]
        for episode in json(data)["episodes"] as? [[String: Any]] ?? [] {
            guard episode["episode_number"] != nil else { continue }
            let number = Lossy.int(episode["episode_number"])
            out[number] = EpisodeMeta(
                name: Lossy.string(episode["name"]), overview: Lossy.string(episode["overview"]),
                still: Self.imageUrl(Lossy.string(episode["still_path"]), size: .still),
                runtimeMinutes: Lossy.int(episode["runtime"]))
        }
        return out
    }

    // MARK: Provider logos (official, from TMDB)

    private let logoLock = NSLock()
    private var logoPaths: [Int: String]?

    private func ensureLogos() async {
        logoLock.lock()
        let loaded = logoPaths != nil
        logoLock.unlock()
        if loaded { return }
        var map: [Int: String] = [:]
        if let data = try? await cachedGet("providers_movie", path: "watch/providers/movie", query: ["watch_region": "US"]) {
            for provider in json(data)["results"] as? [[String: Any]] ?? [] {
                let id = Lossy.int(provider["provider_id"])
                let path = Lossy.string(provider["logo_path"])
                if id != 0, !path.isEmpty { map[id] = path }
            }
        }
        logoLock.lock()
        logoPaths = map
        logoLock.unlock()
    }

    func providerLogoUrl(_ provider: Provider) async -> String? {
        await ensureLogos()
        logoLock.lock()
        defer { logoLock.unlock() }
        guard let path = provider.ids.lazy.compactMap({ self.logoPaths?[$0] }).first else { return nil }
        return Self.imageUrl(path, size: .logo)
    }
}

extension Lossy {
    static func double(_ value: Any?) -> Double {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }
}
