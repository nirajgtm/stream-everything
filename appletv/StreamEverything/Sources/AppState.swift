import Foundation
import SwiftUI
import Combine

/// Loaded catalogs, search, and the shared services every screen uses.
@MainActor
final class AppState: ObservableObject {
    let account = AccountStore()
    let settings = Settings()
    let resume = ResumeStore()
    let tmdb = TmdbClient()
    let watchmode = WatchmodeClient()
    let affinity = PlatformAffinity()
    let sourceChoices = SourceChoiceStore()
    let homeCache = HomeCache()
    /// Local copies of VOD files and the loopback server VLC plays them from.
    let mediaStore = MediaStore()
    lazy var mediaDownloader = MediaDownloader(store: mediaStore)
    lazy var mediaServer = LocalMediaServer(store: mediaStore, downloader: mediaDownloader)

    /// Hand VLC the local URL for a VOD file and mark the title as played.
    func playableURL(for remote: URL) -> URL { mediaServer.localURL(for: remote) }

    /// Start pulling `remote` into the peek tier from `fraction` of the way in, so Play
    /// on the page in front of the viewer starts at once.
    var prefetchDisabled = false

    func prefetch(_ remote: URL, fromFraction fraction: Double, allowWhilePlaying: Bool = false) {
        guard !prefetchDisabled else { return }
        guard allowWhilePlaying || !isPlaying else { return }   // the player owns the connection while it runs
        let entry = mediaStore.open(remote, tier: .peek)
        mediaDownloader.prefetch(entry, fromFraction: max(0, min(0.98, fraction)))
    }

    /// A tile the viewer has rested on for a while: pull in what its page would play
    /// (the preferred copy of a movie, the episode Play would start for a series)
    /// so the page and the first Play are instant.
    func prefetchForDwell(_ entry: Entry) {
        guard !isPlaying else { return }
        switch entry.kind {
        case .movie:
            var found = sourcesFor(name: entry.name, isSeries: false)
            if !found.contains(where: { $0.id == entry.id }) { found.insert(entry, at: 0) }
            let preferred = sourceChoices.preferred(among: SourceChoiceStore.englishFirst(found), fallback: entry)
            let mark = resume.mark(for: ResumeStore.movieKey(preferred.id))
            prefetch(client.movieUrl(preferred), fromFraction: mark?.fraction ?? 0)
        case .series:
            let model = SeriesEpisodesModel(entry: entry)
            Task { @MainActor in
                await model.open(app: self, applySavedChoice: true)
                guard !isPlaying, let episode = model.heroEpisode(app: self) else { return }
                let mark = resume.mark(for: ResumeStore.episodeKey(episode.id))
                prefetch(client.episodeUrl(episode), fromFraction: mark?.fraction ?? 0)
            }
        case .live: break
        }
    }

    /// How much of `remote` is on disk from `fraction` onward, 0...1 of the file, for
    /// the "ready to play" hint. Nil when nothing is known yet.
    func prefetchedFraction(of remote: URL) -> Double? {
        guard let entry = mediaStore.entry(for: remote), entry.totalLength > 0 else { return nil }
        return Double(entry.cachedBytes) / Double(entry.totalLength)
    }

    /// Rebuilt from `account` after a switch; everything that streams reads it live.
    @Published private(set) var client: XtreamClient

    @Published var live: [Entry] = []
    @Published var movies: [Entry] = []
    @Published var series: [Entry] = []
    @Published var status = "Starting..."
    @Published var ready = false
    /// Mirror of `settings.adultFilter` so the search and rail code can read one flag.
    @Published var adultFilter = true

    /// The TMDB home rails (Trending + one per provider), from the snapshot first.
    @Published var homeRails: [RailData] = []
    @Published var homeRailsMessage = ""

    /// The home navigation stack. Lives here so a pushed page (a provider hub, say)
    /// can push the next one without threading a binding through every view.
    @Published var path: [AppRoute] = []

    func push(_ route: AppRoute) { path.append(route) }

    /// Test hook: a search typed for the home screen at launch.
    @Published var launchQuery = ""

    /// Launch arguments used by the simulator test driver to open a screen directly:
    /// --live, --live=Hindi, --sports, --settings, --movie=<stream id>, --series=<series id>, --hub=<provider key>.
    func applyLaunchArguments() {
        for argument in ProcessInfo.processInfo.arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "--live": push(.liveBrowse(language: parts.count > 1 ? parts[1] : nil))
            case "--sports": push(.sports)
            case "--query": launchQuery = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ") : ""
            case "--source":   // test hook: --source=<id>[:explicit] saves that copy as the title's choice
                if let spec = parts.last {
                    let bits = spec.split(separator: ":").map(String.init)
                    if let id = bits.first.flatMap(Int.init), let entry = entry(kind: .movie, id: id) {
                        sourceChoices.remember(entry, explicit: bits.count > 1)
                    }
                }
            case "--favorite": if let id = parts.last.flatMap(Int.init), !LiveMemory.shared.isFavorite(id) { LiveMemory.shared.toggleFavorite(id) }
            case "--no-prefetch": prefetchDisabled = true   // simulator checks must not take the stream slot
            case "--settings": push(.settings)
            case "--hub": if let key = parts.last.flatMap(Int.init) { push(.providerHub(key)) }
            case "--movie": if let id = parts.last.flatMap(Int.init), let entry = entry(kind: .movie, id: id) { push(.movie(entry)) }
            case "--series": if let id = parts.last.flatMap(Int.init), let entry = entry(kind: .series, id: id) { push(.series(entry)) }
            default: break
            }
        }
    }

    private var subscriptions: Set<AnyCancellable> = []
    private var loadGeneration = 0

    /// Newest first: the provider appends new titles at the end of each list.
    var recentMovies: [Entry] { Array(movies.suffix(40).reversed()) }
    var recentSeries: [Entry] { Array(series.suffix(40).reversed()) }

    init() {
        client = account.makeClient()
        adultFilter = settings.adultFilter
        settings.$adultFilter.sink { [weak self] on in self?.adultFilter = on }.store(in: &subscriptions)
        settings.$trendingRegion.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { await self?.refreshHomeRails() }
        }.store(in: &subscriptions)
        // The account form and the resume store are owned objects; views observe AppState
        // only, so forward their changes.
        account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        resume.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        // A snapshot from older matching rules still paints instantly but is rebuilt
        // right after load (age() reports it as stale).
        homeRails = homeCache.load()?.rails ?? []
    }

    // MARK: Loading

    /// True while the player is on screen. The account allows one stream, so no
    /// catalog download runs while something plays.
    @Published var isPlaying = false { didSet { mediaDownloader.setPlaybackActive(isPlaying) } }
    /// Live TV streams straight from the provider, so the downloader must stay quiet.
    @Published var isPlayingLive = false { didSet { mediaDownloader.setSuspended(isPlayingLive) } }
    private var refreshTask: Task<Void, Never>?

    func load() async {
        guard account.isConfigured else {
            status = "Set up your Xtream account to get started."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let client = self.client
        // Home paints right away from the snapshot; the catalogs fill in underneath.
        ready = true
        status = client.hasCachedCatalogs() ? "Opening catalog..." : "Downloading catalog..."
        let order: [Kind] = [.live, .series, .movie]
        for kind in order {
            do {
                let cached = await Task.detached(priority: .userInitiated) { client.cachedCatalog(kind) }.value
                let entries: [Entry]
                if let cached {
                    entries = cached
                } else {
                    status = "Downloading \(label(kind))..."
                    entries = try await Task.detached(priority: .userInitiated) { try await client.downloadCatalog(kind) }.value
                }
                guard generation == loadGeneration else { return }   // an account switch restarted us
                publish(kind, entries)
            } catch {
                status = "Could not load \(label(kind)): \(error.localizedDescription)"
                return
            }
        }
        updateReadyStatus()
        applyLaunchArguments()
        await warmTitleIndexes()
        await refreshHomeRailsIfStale()
        scheduleBackgroundRefresh()
    }

    private func label(_ kind: Kind) -> String {
        switch kind { case .live: "live channels"; case .movie: "movies"; case .series: "series" }
    }

    private func publish(_ kind: Kind, _ entries: [Entry]) {
        switch kind {
        case .live: live = entries
        case .series: series = entries
        case .movie: movies = entries
        }
    }

    /// Re-download catalogs older than a day, one at a time at low priority, swapping
    /// each in when parsed. Waits while the player is up and checks again hourly, so a
    /// refresh is never felt: nothing blocks, nothing competes with a stream.
    func scheduleBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStaleCatalogs()
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            }
        }
    }

    private func refreshStaleCatalogs() async {
        let client = self.client
        let generation = loadGeneration
        for kind in Kind.allCases where client.catalogIsStale(kind) {
            while isPlaying { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            if Task.isCancelled || generation != loadGeneration { return }
            guard let fresh = try? await Task.detached(priority: .background) { try await client.downloadCatalog(kind) }.value,
                  generation == loadGeneration else { continue }
            publish(kind, fresh)
            updateReadyStatus()
            CatalogIndexStore.shared.forgetAll()
        }
        await warmTitleIndexes()
    }

    /// Home status line, as the Android app words it.
    func updateReadyStatus() {
        status = "Type to search  ·  \(live.count) channels, \(movies.count) movies, \(series.count) series"
    }

    /// A different account was saved and its cache wiped: drop everything that belonged
    /// to the old subscription and load again from scratch.
    func reloadAfterAccountChange() {
        client = account.makeClient()
        live = []; movies = []; series = []
        path = []
        ready = false
        status = "Loading new account..."
        CatalogIndexStore.shared.forgetAll()
        CatalogMemo.shared.forgetAll()
        homeCache.clear()
        homeRails = []
        Task { await load() }
    }

    // MARK: Lookups

    func entry(kind: Kind, id: Int) -> Entry? {
        let list = switch kind { case .live: live; case .movie: movies; case .series: series }
        return list.first { $0.id == id }
    }

    /// Titles matching every word of [query], best matches first. Capped so typing stays quick.
    func search(_ query: String, limit: Int = 60) -> [Entry] {
        let words = query.split(separator: " ").map { TitleText.searchKey(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let whole = words.joined()
        var exact: [Entry] = [], partial: [Entry] = []
        for list in [movies, series, live] {
            for entry in list {
                if adultFilter && entry.adult { continue }
                let key = entry.searchKey
                if key.contains(whole) {
                    exact.append(entry)
                } else if words.allSatisfy({ key.contains($0) }) {
                    partial.append(entry)
                }
                if exact.count >= limit { break }
            }
        }
        return Array((exact + partial).prefix(limit))
    }

    // MARK: Home rails (TMDB)

    /// Refresh the TMDB rails only when the on-disk snapshot is missing or older than
    /// six hours; otherwise the snapshot painted at launch is what you get.
    func refreshHomeRailsIfStale() async {
        let sixHours: TimeInterval = 6 * 60 * 60
        guard homeCache.age() > sixHours else { return }
        await refreshHomeRails()
    }

    /// Rebuild every TMDB rail in the background and re-save the snapshot.
    func refreshHomeRails() async {
        guard tmdb.configured else {
            if homeRails.isEmpty { homeRailsMessage = "Add a TMDB key to see trending rails." }
            return
        }
        // Nothing to match against yet (cold start, account switch): a build now would
        // save empty rails and hide them until the next refresh.
        guard !movies.isEmpty, !series.isEmpty else { return }
        if homeRails.isEmpty { homeRailsMessage = "Loading what's trending today..." }
        let resolver = CatalogResolver(app: self)
        let tmdb = self.tmdb, watchmode = self.watchmode
        let region = settings.trendingRegion
        tmdb.regions = settings.trendingRegionCodes
        let rails = await Task.detached(priority: .utility) { () -> [RailData] in
            let trending = (try? await tmdb.trendingWithProviders(region: region)) ?? []
            var collected: [Int: RailData] = [:]
            let trendingTitle = "Trending"
            if let rail = resolver.rail(title: trendingTitle, items: trending, cap: 60) { collected[-1] = rail }
            // Four providers at a time, like the Android thread pool: enough to overlap
            // the network, not enough to starve the UI.
            await withTaskGroup(of: (Int, RailData?).self) { group in
                var next = 0
                let providers = TmdbClient.providers
                func enqueue(_ group: inout TaskGroup<(Int, RailData?)>) {
                    guard next < providers.count else { return }
                    let index = next
                    next += 1
                    group.addTask {
                        let provider = providers[index]
                        let trendingOn = trending.filter { tmdb.onProvider($0, provider) }
                        var seen = Set<Int>()
                        let padded = (trendingOn + (await tmdb.popularOn(provider))).filter { seen.insert($0.tmdbId).inserted }
                        let ranks = await watchmode.popularRanks(sourceId: provider.watchmodeId)
                        let ordered = watchmode.reorder(padded, by: ranks)
                        let logo = await tmdb.providerLogoUrl(provider) ?? ""
                        return (index, resolver.rail(title: "Popular on \(provider.label)", items: ordered, cap: 20,
                                                     providerKey: provider.key, logoUrl: logo))
                    }
                }
                for _ in 0..<min(4, providers.count) { enqueue(&group) }
                for await (index, rail) in group {
                    if let rail { collected[index] = rail }
                    enqueue(&group)
                }
            }
            return ([-1] + TmdbClient.providers.indices).compactMap { collected[$0] }
        }.value
        // Rails are dropped when they have no cards, so an all-empty result means the
        // network or the matching failed; keep what is on screen rather than save it.
        guard rails.contains(where: { !$0.cards.isEmpty }) else {
            if homeRails.isEmpty { homeRailsMessage = "Could not load trending titles." }
            return
        }
        // A provider whose fetch came back empty this time keeps its previous rail:
        // one bad refresh must not shrink the home screen until the next good one.
        let fresh = Set(rails.map(\.providerKey))
        let kept = homeRails.filter { !fresh.contains($0.providerKey) && !$0.cards.isEmpty }
        let merged = ([-1] + TmdbClient.providers.indices.map { TmdbClient.providers[$0].key }).compactMap { key in
            rails.first { $0.providerKey == key } ?? kept.first { $0.providerKey == key }
        }
        NSLog("UI rails fresh=%d kept=%d: %@", rails.count, kept.count, merged.map { "\($0.title)=\($0.cards.count)" }.joined(separator: " "))
        homeRails = merged
        homeRailsMessage = ""
        homeCache.save(rails: merged)
    }

    /// Catalog entry behind a saved rail card, or nil when it is gone from the catalog.
    func entry(for card: CardData) -> Entry? {
        if let hit = entry(kind: card.kind, id: card.entryId) { return adultFilter && hit.adult ? nil : hit }
        return findByTitle(card.display, isSeries: card.kind == .series)
    }
}

/// A thread-safe view of the title indexes, built on the main actor and then used
/// from the background rail builder so resolving a few thousand TMDB titles never
/// hops back to the UI.
struct CatalogResolver: @unchecked Sendable {   // TitleIndex is immutable once built
    private let movies: TitleIndex
    private let series: TitleIndex
    private let adultFilter: Bool
    private let startedMovieIds: Set<Int>

    @MainActor
    init(app: AppState) {
        movies = CatalogIndexStore.shared.index(for: .movie, entries: app.movies)
        series = CatalogIndexStore.shared.index(for: .series, entries: app.series)
        adultFilter = app.adultFilter
        startedMovieIds = Set(app.resume.marks.values.filter { $0.kind == .movie && !$0.finished }.map { $0.entryId })
    }

    func find(_ item: TmdbItem) -> Entry? {
        let found = (item.isSeries ? series : movies).find(title: item.title)
        if let found, adultFilter, found.adult { return nil }
        // Same name, different film: a Nepali "Acharya" must not open the Telugu
        // "Acharya (2022)". When both sides carry a year they have to agree (one year
        // of slack for release-date differences between regions).
        if let found, let catalogYear = TitleParser.parse(found.name).year.flatMap(Int.init),
           let tmdbYear = Int(item.year), abs(catalogYear - tmdbYear) > 1 {
            return nil
        }
        // A Nepali film must not resolve to an Indian-tagged copy of a namesake, and the
        // other way round: the copy's country tag has to be compatible with the film's
        // original language. English and untagged copies pass.
        if let found, Self.conflicts(language: item.originalLanguage, labelTokens: LanguagePreference.labelTokens(found.name)) {
            return nil
        }
        return found
    }

    /// Country tags a film in each language would legitimately carry.
    private static let countriesForLanguage: [String: Set<String>] = [
        "ne": ["NP"], "hi": ["IN"], "ta": ["IN"], "te": ["IN"], "ml": ["IN"], "kn": ["IN"], "bn": ["IN", "BD"],
        "mr": ["IN"], "pa": ["IN", "PK"], "gu": ["IN"], "ur": ["PK", "IN"], "ko": ["KR"], "ja": ["JP"],
        "zh": ["CN", "TW", "HK"], "tr": ["TR"], "ar": ["AR", "EG", "SA", "AE", "MA"], "fa": ["IR"]
    ]
    private static let countryTags: Set<String> = ["NP", "IN", "BD", "PK", "KR", "JP", "CN", "TW", "HK", "TR", "AR", "EG", "SA", "AE", "MA", "IR"]

    private static func conflicts(language: String, labelTokens: [String]) -> Bool {
        guard let allowed = countriesForLanguage[language] else { return false }
        let tagged = labelTokens.filter { countryTags.contains($0) }
        return !tagged.isEmpty && !tagged.contains { allowed.contains($0) }
    }

    /// Rail of the TMDB items this catalog can play, capped, movies you started first
    /// (the Android ordering). Nil when nothing resolves so the slot stays empty.
    func rail(title: String, items: [TmdbItem], cap: Int, providerKey: Int = -1, logoUrl: String = "") -> RailData? {
        var cards: [CardData] = []
        for item in items {
            guard let entry = find(item) else { continue }
            cards.append(CardData(display: item.title, name: entry.name, kind: entry.kind, entryId: entry.id,
                                  ext: entry.ext, poster: item.posterUrl, overview: item.overview,
                                  tmdbId: item.tmdbId, year: item.year))
            if cards.count >= cap { break }
        }
        guard !cards.isEmpty else { return nil }
        let started = cards.filter { $0.kind == .movie && startedMovieIds.contains($0.entryId) }
        let rest = cards.filter { !($0.kind == .movie && startedMovieIds.contains($0.entryId)) }
        return RailData(title: title, providerKey: providerKey, logoUrl: logoUrl, cards: started + rest)
    }
}
