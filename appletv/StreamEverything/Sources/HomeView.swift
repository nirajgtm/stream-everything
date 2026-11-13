import SwiftUI

/// Home: status line, search row with the Settings gear, then either the search
/// results (kind and language chips, paged grid) or the rails in the Android order:
/// Trending Today, Live TV, Continue Playing, then one "Popular on <service>" rail
/// per provider ordered by how much you watch each. Port of the Android
/// `MainActivity` home and results modes; the series mode is `SeriesView`.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var searchMode = false
    @State private var searchButtonEnabled = true
    @StateObject private var continueExpansion = CardExpansion()
    @FocusState private var focusedContinue: String?
    @State private var selectedKind: Kind?
    @State private var selectedLanguage: String?
    @State private var results: [Entry] = []
    @State private var availability: AppState.Availability?
    @State private var resultsLimit = 100
    @State private var resultsStatus = ""
    /// Clean titles TMDB proposes for what has been typed so far.
    @State private var suggestions: [String] = []
    @State private var orderedProviderRails: [RailData] = []
    @State private var playing: PlayRequest?
    @State private var toast: ToastMessage?
    @FocusState private var searchFocused: Bool

    private let pageSize = 100

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var recent: [ResumeStore.Mark] { app.resume.recent() }
    private var trendingRail: RailData? { app.homeRails.first { $0.providerKey == -1 } }
    private var startedMovieIds: Set<Int> {
        Set(app.resume.marks.values.filter { $0.kind == .movie && !$0.finished }.map { $0.entryId })
    }

    /// Everything a search depends on; the debounced task re-runs when any part changes.
    private struct SearchKey: Equatable {
        let query: String
        let kind: Kind?
        let language: String?
        let limit: Int
    }
    private var searchKey: SearchKey { SearchKey(query: query, kind: selectedKind, language: selectedLanguage, limit: resultsLimit) }

    var body: some View {
        ZStack {
            Theme.chrome.ignoresSafeArea()
            if searchMode {
                searchLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        HStack(spacing: 20) {
                            Button { searchMode = true } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "magnifyingglass")
                                    Text(query.isEmpty ? "Search channels, movies, series" : query)
                                        .foregroundStyle(query.isEmpty ? Theme.muted : .white)
                                    Spacer()
                                }
                                .font(.system(size: 24))
                                .padding(.horizontal, 24).padding(.vertical, 14)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HeroButtonStyle())
                            .disabled(!searchButtonEnabled)
                            .focused($searchFocused)
                            NavigationLink(value: AppRoute.settings) {
                                Image(systemName: "gearshape.fill").font(.system(size: 26))
                            }
                            .accessibilityLabel("Settings")
                        }
                        .padding(.horizontal, 60)
                        Text(app.status).font(.system(size: 20)).foregroundStyle(Theme.accent).padding(.horizontal, 60)
                        // Coming back from search (or launching) lands on the content,
                        // not on the search button, so Menu from here leaves the app only
                        // after a deliberate second press from the top.
                        // From anywhere in the rails, Menu goes to the top (focus on the
                        // search row, the scroll follows); from the top row it leaves the app.
                        homeRails
                            .onExitCommand(perform: searchFocused ? nil : { searchFocused = true })
                    }
                    .padding(.vertical, 30)
                }
            }
        }
        .overlay(ToastOverlay(toast: $toast))
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
        .task(id: searchKey) { await runSearch() }
        .onChange(of: query) { previous, text in
            // Closing the on-screen keyboard with Menu reverts the field to what it held
            // before typing, wiping a search in one jump. Deleting by hand passes through
            // one character first, so a jump from several characters to none is the
            // keyboard cancel: keep what was typed, as the Android app does.
            if text.isEmpty, previous.count > 1 {
                query = previous
                return
            }
            checkFilterPhrase(text)
            resultsLimit = pageSize
        }
        .onAppear { reorderProviderRails() }
        .onChange(of: app.launchQuery) { _, text in
            guard !text.isEmpty else { return }
            searchMode = true; query = text; app.launchQuery = ""
        }
        .onChange(of: app.homeRails) { _, _ in reorderProviderRails() }
    }

    // MARK: Search row and filters

    /// Search mode: the keyboard keeps a column on the left and the results update on
    /// the right as keys are pressed. Menu leaves search and clears it.
    private var searchLayout: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    Text(query.isEmpty ? "Type to search" : query)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(query.isEmpty ? Theme.muted : .white)
                        .lineLimit(1)
                }
                .frame(width: 400, alignment: .leading)
                SearchKeyboard(text: $query)
                // Title suggestions under the keyboard, the way the Netflix app does
                // it: picking one fills the search with the exact name.
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(suggestions.prefix(6), id: \.self) { title in
                            Button {
                                query = title
                            } label: {
                                Text(title).font(.system(size: 22)).lineLimit(1)
                                    .frame(width: 400, alignment: .leading)
                            }
                            .buttonStyle(SuggestionStyle())
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.leading, 60).padding(.top, 50)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(searching ? resultsStatus : "Type to search  ·  \(app.live.count) channels, \(app.movies.count) movies, \(app.series.count) series")
                        .font(.system(size: 20)).foregroundStyle(Theme.accent)
                    if searching {
                        filterRow
                        resultsGrid
                    }
                }
                .padding(.top, 50).padding(.trailing, 60).padding(.bottom, 40)
            }
        }
        .onExitCommand {
            // Focus would otherwise return to the search button, so a second Menu
            // would leave the app; keep the button out of reach for a moment so focus
            // lands on the first rail instead.
            searchButtonEnabled = false
            searchMode = false; query = ""; selectedKind = nil; selectedLanguage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { searchButtonEnabled = true }
        }
    }

    private var kindChips: [(Kind?, String)] { [(nil, "All"), (.live, "Live"), (.movie, "Movies"), (.series, "Series")] }

    /// Kind chips with counts, then language chips with counts. Kinds without a single
    /// match disappear unless selected, so you never pick a filter that leads nowhere.
    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(kindChips, id: \.1) { kind, base in
                    let count = kind.flatMap { availability?.kinds[$0] }
                    let hidden = kind != nil && availability != nil && (count ?? 0) == 0 && selectedKind != kind
                    if !hidden {
                        Button(count.map { "\(base) (\($0))" } ?? base) { selectedKind = kind; resultsLimit = pageSize }
                            .buttonStyle(ChipButtonStyle(selected: selectedKind == kind))
                    }
                }
                Button("Clear") { query = ""; selectedKind = nil; selectedLanguage = nil }
                    .buttonStyle(ChipButtonStyle())
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    let untagged = availability?.untagged ?? 0
                    Button(untagged > 0 ? "All languages (+\(untagged) untagged)" : "All languages") {
                        selectedLanguage = nil; resultsLimit = pageSize
                    }
                    .buttonStyle(ChipButtonStyle(selected: selectedLanguage == nil))
                    ForEach(languageChips, id: \.0) { code, count in
                        Button(count > 0 ? "\(code) (\(count))" : code) { selectedLanguage = code; resultsLimit = pageSize }
                            .buttonStyle(ChipButtonStyle(selected: selectedLanguage == code))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// Languages with matches, most first; the whole catalog's list before counts arrive.
    private var languageChips: [(String, Int)] {
        if let availability {
            var chips = availability.languages.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { ($0.key, $0.value) }
            if let selectedLanguage, !chips.contains(where: { $0.0 == selectedLanguage }) { chips.insert((selectedLanguage, 0), at: 0) }
            return chips
        }
        return app.languages().map { ($0, 0) }
    }

    // MARK: Results

    private var resultsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 20), count: 4), alignment: .leading, spacing: 30) {
            ForEach(results) { entry in
                Button { openResult(entry) } label: { SearchResultCard(entry: entry) }
                    .buttonStyle(.card)
                    .onAppear {
                        // Reaching the last card asks for the next page.
                        if entry.id == results.last?.id, results.count >= resultsLimit { resultsLimit += pageSize }
                    }
            }
        }
    }

    /// Debounced so a burst of keystrokes runs one search; the facet counts are a
    /// full-catalog pass, so they come after the page shows.
    private func runSearch() async {
        guard searching else { results = []; availability = nil; suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        guard ParsedQuery(query).valid else {
            results = []; availability = nil
            resultsStatus = "Type at least 2 characters to search."
            return
        }
        async let suggested = app.suggestedEntries(for: query)
        let typed = query
        let page = await app.fuzzySearch(query, kind: selectedKind, language: selectedLanguage, limit: resultsLimit)
        guard !Task.isCancelled else { return }
        results = page
        // Suggested titles lead the results once TMDB answers (it is a network call,
        // the catalog search is not), filtered like the rest and never duplicated.
        let lead = await suggested.filter { entry in
            (selectedKind == nil || entry.kind == selectedKind) &&
            (selectedLanguage == nil || TitleParser.languageCode(of: entry.name) == nil || TitleParser.languageCode(of: entry.name) == selectedLanguage)
        }
        guard !Task.isCancelled else { return }
        if !lead.isEmpty {
            let leadIds = Set(lead.map(\.id))
            results = lead + page.filter { !leadIds.contains($0.id) }
        }
        // Distinct clean names from the best matches (TMDB's completions first, then
        // the closest catalog hits), skipping one that is exactly what was typed.
        var names: [String] = []
        for entry in lead + results.prefix(40) {
            let clean = TitleParser.parse(entry.name).clean
            if clean.lowercased() != typed.lowercased(), !names.contains(where: { $0.lowercased() == clean.lowercased() }) {
                names.append(clean)
            }
        }
        // Shortest names first: "Game of Thrones" before its spin-offs and podcasts.
        suggestions = Array(names.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }.prefix(6))
        let kindLabel = selectedKind.map { $0.rawValue } ?? "all types"
        let languageLabel = selectedLanguage ?? "all languages"
        resultsStatus = "\(page.count)\(page.count >= resultsLimit ? "+" : "") results  (\(kindLabel), \(languageLabel))"
        await Task.yield()
        guard !Task.isCancelled else { return }
        availability = app.availability(query: query, kind: selectedKind, language: selectedLanguage)
    }

    /// Search rows open a light episode list per source, so several sources of the
    /// same show can be explored without going through the series page (Android
    /// `onSearchResultClicked`). Rails and Continue Playing open the full series page.
    private func openResult(_ entry: Entry) {
        switch entry.kind {
        case .live: playLive(entry)
        case .movie: app.push(.movie(entry))
        case .series: app.push(.searchEpisodes(entry))
        }
    }

    private func playLive(_ entry: Entry) {
        LiveMemory.shared.recordPlay(entry.id)
        LiveMemory.shared.touchLanguage(LiveBuckets.bucket(of: entry.name))
        var request = PlayRequest(url: app.client.liveUrl(entry), title: entry.displayTitle, isLive: true,
                                  startMs: 0, mark: nil, poster: entry.logo)
        // Zap through the live channels in the current results.
        let liveResults = results.filter { $0.kind == .live }
        request.zapList = liveResults
        request.zapIndex = liveResults.firstIndex(where: { $0.id == entry.id }) ?? 0
        playing = request
    }

    // MARK: Adult filter Easter egg

    /// Typing the unlock phrase in the search box turns the filter off, the lock phrase
    /// turns it back on; the box clears so the phrase never runs as a search.
    private func checkFilterPhrase(_ text: String) {
        if Settings.matchesUnlockPhrase(text) {
            app.settings.unlockAdultFilter(with: text)
            toast = ToastMessage(text: "boobies unlocked")
            query = ""
        } else if Settings.matchesLockPhrase(text) {
            if !app.settings.adultFilter {
                app.settings.lockAdultFilter()
                toast = ToastMessage(text: "No boobies for you!")
            }
            query = ""
        }
    }

    // MARK: Home rails

    private var homeRails: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let trendingRail {
                TmdbRail(rail: trendingRail, startedMovieIds: startedMovieIds) { openCard($0, providerKey: -1) }
            } else if !app.homeRailsMessage.isEmpty {
                Text(app.homeRailsMessage).foregroundStyle(Color(hex: "#557788")).padding(.horizontal, 60)
            }
            LiveTilesRail()
            if !recent.isEmpty { continueRail }
            ForEach(orderedProviderRails) { rail in
                TmdbRail(rail: rail, startedMovieIds: startedMovieIds,
                         onLead: { app.push(.providerHub(rail.providerKey)) },
                         onCard: { openCard($0, providerKey: rail.providerKey) })
            }
        }
    }

    /// Platform rails ordered by affinity. Recomputed when the rails change, not on every
    /// redraw, so they never shuffle under the cursor.
    private func reorderProviderRails() {
        let providerRails = app.homeRails.filter { $0.providerKey != -1 }
        orderedProviderRails = app.affinity.ordered(providerRails) { $0.providerKey }
    }

    private func openCard(_ card: CardData, providerKey: Int) {
        guard let entry = app.entry(for: card) else {
            toast = ToastMessage(text: "\(card.display) is not in your catalog")
            return
        }
        // Watching from a platform rail is what ranks that platform.
        if providerKey != -1 { app.affinity.recordPlay(platformKey: providerKey) }
        switch entry.kind {
        case .movie: app.push(.movie(entry))
        case .series: app.push(.series(entry))
        case .live: playLive(entry)
        }
    }

    /// History of the last plays, one card per series; a long press offers to remove it.
    private var continueRail: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 24) {
                ForEach(recent) { mark in
                    Button { resumeFromHistory(mark) } label: {
                        ExpandingPosterCard(
                            imageUrl: mark.poster,
                            detail: CardDetail(title: mark.title,
                                               meta: mark.durationMs > 0 ? "\(Int(mark.fraction * 100))% watched  ·  \(max(1, (mark.durationMs - mark.positionMs) / 60_000)) min left" : "",
                                               overview: "", tmdbId: 0, isSeries: mark.kind == .series),
                            progress: mark.fraction,
                            buffered: bufferedFraction(for: mark),
                            expanded: continueExpansion.expandedId == mark.id,
                            loadOverview: { await overview(for: mark) })
                    }
                    .buttonStyle(.card)
                    .focused($focusedContinue, equals: mark.id)
                    .contextMenu {
                        Button("Remove from Continue Playing", role: .destructive) { app.resume.remove(mark) }
                        Button("Open") { resumeFromHistory(mark) }
                    }
                    .padding(.top, RailHeader.height)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 20)
        }
        // On the scroll view, not its content, so the title stays put while cards scroll.
        .overlay(alignment: .topLeading) { RailHeader(title: "Continue Playing").allowsHitTesting(false) }
        .onChange(of: continueExpansion.expandedId) { _, id in
            if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
        }
        }
        .onChange(of: focusedContinue) { _, id in continueExpansion.focusChanged(to: id) }
        .onAppear {
            continueExpansion.onDwell = { id in
                guard let mark = recent.first(where: { $0.id == id }), mark.kind != .live else { return }
                guard let entry = app.entry(kind: mark.kind, id: mark.entryId)
                        ?? (mark.kind == .series ? app.seriesForLabel(mark.title)?.series : nil) else { return }
                app.prefetchForDwell(entry)
            }
        }
    }

    /// On-disk share of the file behind a history card.
    private func bufferedFraction(for mark: ResumeStore.Mark) -> Double {
        switch mark.kind {
        case .movie:
            guard let entry = app.entry(kind: .movie, id: mark.entryId) else { return 0 }
            return app.prefetchedFraction(of: app.client.movieUrl(entry)) ?? 0
        case .series:
            let episode = Episode(id: mark.episodeId, season: mark.season, number: mark.episode, title: "", ext: mark.ext ?? "mkv", plot: "", still: "", durationSeconds: 0)
            return app.prefetchedFraction(of: app.client.episodeUrl(episode)) ?? 0
        case .live: return 0
        }
    }

    /// Overview for a history card: TMDB's English text by title, else the provider's.
    private func overview(for mark: ResumeStore.Mark) async -> String {
        let title = mark.kind == .series ? (mark.title.components(separatedBy: " · ").first ?? mark.title) : mark.title
        if let hit = await app.tmdb.match(title: title, year: nil, isSeries: mark.kind == .series), !hit.overview.isEmpty {
            return hit.overview
        }
        if mark.kind == .movie, let info = try? await app.client.movieDetail(streamId: mark.entryId) { return info.plot }
        if mark.kind == .series, let info = try? await app.client.seriesDetail(seriesId: mark.entryId) { return info.plot }
        return ""
    }

    /// Continue Playing opens the movie or series page (not direct playback): a series
    /// lands on the exact season and episode, a movie on its page with Resume focused.
    private func resumeFromHistory(_ mark: ResumeStore.Mark) {
        switch mark.kind {
        case .movie:
            guard let entry = app.entry(kind: .movie, id: mark.entryId) else { return missing(mark) }
            app.push(.movie(entry))
        case .series:
            guard let entry = app.entry(kind: .series, id: mark.entryId)
                    ?? app.seriesForLabel(mark.title)?.series else { return missing(mark) }
            app.push(.series(entry, focusSeason: mark.season, focusEpisode: mark.episode))
        case .live:
            guard let entry = app.entry(kind: .live, id: mark.entryId) else { return missing(mark) }
            playLive(entry)
        }
    }

    private func missing(_ mark: ResumeStore.Mark) {
        toast = ToastMessage(text: "\(mark.title) is no longer in your catalog")
    }
}

/// A search result: poster (or channel logo) with a kind icon, the clean title and
/// its readable pills (language, quality, network, year).
struct SearchResultCard: View {
    let entry: Entry

    private var parsed: ParsedTitle { TitleParser.parse(entry.name) }
    private var icon: String {
        switch entry.kind { case .live: "🔴"; case .movie: "🎬"; case .series: "📺" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.chip
                CachedImage(url: URL(string: entry.logo)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: entry.kind == .live ? .fit : .fill)
                            .padding(entry.kind == .live ? 20 : 0)
                    }
                }
            }
            .frame(width: 220, height: entry.kind == .live ? 124 : 320)
            .clipped()
            Text("\(icon)  \(parsed.clean)").font(.caption).lineLimit(2).frame(width: 220, alignment: .leading)
            PillRow(pills: parsed.pills, compact: true).frame(width: 220, alignment: .leading)
        }
    }
}


/// A suggestion row under the search keyboard: plain text, white pill when focused.
private struct SuggestionStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Theme.page : .white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(focused ? Color.white : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
