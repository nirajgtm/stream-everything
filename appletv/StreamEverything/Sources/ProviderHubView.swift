import SwiftUI

/// A per-provider browse screen: New / Popular Movies / Popular Shows / Top Rated and
/// one rail per genre, all filtered to what the catalog can play. Paints the last
/// snapshot at once and refreshes in the background when it is older than six hours.
/// Port of the Android `ProviderHubActivity`.
struct ProviderHubView: View {
    let provider: TmdbClient.Provider
    @EnvironmentObject var app: AppState
    @State private var rails: [RailData] = []
    @State private var logoUrl = ""
    @State private var message = ""
    @State private var toast: ToastMessage?

    private var cache: HomeCache { HomeCache(name: "hub_\(provider.key)") }
    private var startedMovieIds: Set<Int> {
        Set(app.resume.marks.values.filter { $0.kind == .movie && !$0.finished }.map { $0.entryId })
    }

    var body: some View {
        ZStack {
            Theme.chrome.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if !message.isEmpty { Text(message).foregroundStyle(Theme.muted).padding(.horizontal, 60) }
                    ForEach(rails) { rail in
                        TmdbRail(rail: rail, startedMovieIds: startedMovieIds) { open($0) }
                    }
                }
                .padding(.vertical, 30)
            }
        }
        .overlay(ToastOverlay(toast: $toast))
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 24) {
            ZStack {
                Theme.page
                if !logoUrl.isEmpty {
                    CachedImage(url: URL(string: logoUrl)) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit).padding(10) }
                    }
                }
            }
            .frame(width: 140, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(provider.label).font(.system(size: 38, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 60)
    }

    // MARK: Loading

    private func load() async {
        let tmdb = app.tmdb
        let provider = self.provider
        Task { logoUrl = await tmdb.providerLogoUrl(provider) ?? "" }
        if let snapshot = cache.load() {
            rails = snapshot.rails
            if cache.age() < 6 * 60 * 60 { return }
        } else {
            message = "Loading \(provider.label)..."
        }
        guard tmdb.configured else { message = "Add a TMDB key to browse \(provider.label)."; return }
        let resolver = CatalogResolver(app: app)
        let watchmode = app.watchmode
        let built = await Task.detached(priority: .utility) { () -> [RailData] in
            let wm = provider.watchmodeId
            // Each spec yields TMDB items; Watchmode's per-service ranks reorder them
            // wherever present (empty ranks leave the TMDB order untouched).
            var specs: [(String, () async -> [TmdbItem])] = [
                ("New on \(provider.label)", { watchmode.reorder(await tmdb.newOn(provider), by: await watchmode.newRanks(sourceId: wm)) }),
                ("Popular Movies", { watchmode.reorder(await tmdb.popularMovies(provider), by: await watchmode.popularRanks(sourceId: wm)) }),
                ("Popular Shows", { watchmode.reorder(await tmdb.popularShows(provider), by: await watchmode.popularRanks(sourceId: wm)) }),
                ("Top Rated", { await tmdb.topRated(provider) })   // Watchmode has no rating sort
            ]
            for genre in TmdbClient.genres {
                specs.append((genre.label, {
                    watchmode.reorder(await tmdb.byGenre(provider, genre),
                                      by: await watchmode.genreRanks(sourceId: wm, watchmodeGenreId: genre.watchmodeId))
                }))
            }
            var collected: [Int: RailData] = [:]
            await withTaskGroup(of: (Int, RailData?).self) { group in
                var next = 0
                func enqueue(_ group: inout TaskGroup<(Int, RailData?)>) {
                    guard next < specs.count else { return }
                    let index = next
                    next += 1
                    let (title, fetch) = specs[index]
                    group.addTask { (index, resolver.rail(title: title, items: await fetch(), cap: 20)) }
                }
                for _ in 0..<min(4, specs.count) { enqueue(&group) }
                for await (index, rail) in group {
                    if let rail { collected[index] = rail }
                    enqueue(&group)
                }
            }
            return specs.indices.compactMap { collected[$0] }
        }.value
        if built.isEmpty {
            if rails.isEmpty { message = "Nothing from \(provider.label) is in your catalog right now." }
            return
        }
        rails = built
        message = ""
        cache.save(rails: built)
    }

    // MARK: Opening a card

    private func open(_ card: CardData) {
        guard let entry = app.entry(for: card) else {
            toast = ToastMessage(text: "\(card.display) is not in your catalog")
            return
        }
        // Watching from this hub ranks the platform on the home rails.
        app.affinity.recordPlay(platformKey: provider.key)
        switch entry.kind {
        case .movie: app.push(.movie(entry))
        case .series: app.push(.series(entry))
        case .live: break
        }
    }
}
