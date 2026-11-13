import SwiftUI

/// Movie detail: dimmed backdrop, poster with the watched bar, clean title with pills,
/// Play / Resume / Play from start, the SOURCES picker, plot and cast headshots.
/// Port of the Android `DetailActivity`.
struct MovieView: View {
    /// The copy the viewer opened; the page may switch to a better source of the same title.
    let entry: Entry
    @EnvironmentObject var app: AppState
    @State private var current: Entry
    @State private var sources: [Entry] = []
    @State private var info: MovieInfo?
    @State private var detailsFailed = false
    @State private var cast: [TmdbClient.CastMember] = []
    @State private var playing: PlayRequest?
    @State private var toast: ToastMessage?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case play }

    init(entry: Entry) {
        self.entry = entry
        _current = State(initialValue: entry)
    }

    private var parsed: ParsedTitle { TitleParser.parse(current.name) }
    private var resumeKey: String { ResumeStore.movieKey(current.id) }
    private var mark: ResumeStore.Mark? { app.resume.mark(for: resumeKey) }
    private var canResume: Bool { mark.map { !$0.finished && $0.positionMs > 0 } ?? false }
    private var posterUrl: String {
        if let tmdbPoster, !tmdbPoster.isEmpty { return tmdbPoster }
        return (info?.poster.isEmpty == false) ? info!.poster : current.logo
    }
    /// TMDB's poster at w780; provider art is often a small upscaled copy.
    @State private var tmdbPoster: String?
    @State private var tmdbBackdrop: String?
    @State private var originalLanguage = ""
    /// TMDB's English overview when it knows the film; the provider text otherwise.
    @State private var englishPlot: String?
    private var displayPlot: String { englishPlot ?? info?.plot ?? "" }

    private var metaLine: String {
        guard let info else { return "" }
        return [info.year, info.genre,
                info.durationSeconds > 0 ? "\(info.durationSeconds / 60) min" : "",
                info.rating.isEmpty ? "" : "★ \(info.rating)"]
            .filter { !$0.isEmpty }.joined(separator: "   •   ")
    }

    var body: some View {
        ZStack {
            BackdropLayer(url: tmdbBackdrop ?? ((info?.backdrop.isEmpty == false) ? info!.backdrop : posterUrl))
            ScrollView {
                HStack(alignment: .top, spacing: 48) {
                    poster
                    VStack(alignment: .leading, spacing: 18) {
                        Text(parsed.clean).font(.system(size: 46, weight: .bold)).lineLimit(2)
                        PillRow(pills: parsed.pills)
                        if !metaLine.isEmpty { Text(metaLine).font(.system(size: 20)).foregroundStyle(Theme.muted) }
                        buttons
                        WatchedBar(watched: mark.map { $0.durationMs > 0 ? min($0.fraction, 1) : 0 } ?? 0,
                                   buffered: app.prefetchedFraction(of: app.client.movieUrl(current)) ?? 0)
                            .frame(width: 360)
                        SourcePills(sources: sources, selectedId: current.id,
                                    upgradeId: app.sourceChoices.upgradeHint(among: sources, for: entry)?.id) { switchSource($0) }
                        plot
                        CastRow(members: cast)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 60).padding(.vertical, 48)
            }
        }
        .defaultFocus($focus, .play)
        .overlay(ToastOverlay(toast: $toast))
        .task { NSLog("UI movie page %@ id=%d", entry.name, entry.id); await openPreferredSource(); NSLog("UI movie sources=%d info=%d failed=%d", sources.count, info == nil ? 0 : 1, detailsFailed ? 1 : 0) }
        // Source pills arrive with the first layout and pull focus with them; put it
        // on Play the moment they land (details and cast keep loading underneath).
        .onChange(of: sources.count) { _, count in
            guard count > 0 else { return }
            Task { try? await Task.sleep(nanoseconds: 120_000_000); focus = .play }
        }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
    }

    private var poster: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.chip
            CachedImage(url: URL(string: posterUrl)) { phase in
                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
            }
            if let mark, mark.durationMs > 0, mark.fraction > 0.02 {
                GeometryReader { geo in
                    Rectangle().fill(Theme.accent)
                        .frame(width: geo.size.width * min(mark.fraction, 1), height: 8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(width: 360, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var buttons: some View {
        HStack(spacing: 20) {
            if canResume, let mark {
                Button { play(fromStart: false) } label: { Text("▶  Resume (\(max(1, mark.positionMs / 60000))m)") }
                    .buttonStyle(HeroButtonStyle(primary: true))
                    .focused($focus, equals: .play)
                Button("Play from start") { play(fromStart: true) }
                    .buttonStyle(HeroButtonStyle())
            } else {
                Button("▶  Play") { play(fromStart: true) }
                    .buttonStyle(HeroButtonStyle(primary: true))
                    .focused($focus, equals: .play)
            }
        }
        .padding(.top, 6)
        // Full width as a focus section, so Up from any source pill lands on the row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    @ViewBuilder
    private var plot: some View {
        if let info {
            Text(displayPlot.isEmpty ? "No description available." : displayPlot)
                .font(.system(size: 22)).foregroundStyle(Color(hex: "#CCD6DD")).lineSpacing(5)
        } else if detailsFailed {
            Text("Details unavailable (provider offline). You can still play.")
                .font(.system(size: 22)).foregroundStyle(Theme.muted)
        } else {
            Text("Loading details...").font(.system(size: 22)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Sources

    /// Collect every copy of this title, then open the saved or English one.
    private func openPreferredSource() async {
        var found = app.sourcesFor(name: entry.name, isSeries: false)
        if !found.contains(where: { $0.id == entry.id }) { found.insert(entry, at: 0) }
        sources = SourceChoiceStore.englishFirst(found)
        let preferred = app.sourceChoices.preferred(among: sources, fallback: entry)
        current = preferred
        // Pull the file in from the resume point so Play starts at once.
        app.prefetch(app.client.movieUrl(current), fromFraction: mark?.fraction ?? 0)
        await loadDetails()
    }

    private func switchSource(_ source: Entry) {
        guard source.id != current.id else { return }
        let previous = mark
        current = source
        app.sourceChoices.remember(source, explicit: true)   // a hand pick sticks, even past a better copy
        info = nil; cast = []; detailsFailed = false; englishPlot = nil; tmdbPoster = nil; tmdbBackdrop = nil
        toast = ToastMessage(text: "Source: \(SourceChoiceStore.pillLabel(source))")
        Task {
            await loadDetails()
            // Same film, other copy: keep the place, unless the lengths say it is another cut.
            if let previous, current.id == source.id {
                app.resume.carry(previous, toKey: resumeKey, entryId: current.id, episodeId: 0,
                                 targetDurationMs: (info?.durationSeconds ?? 0) * 1000, ext: nil)
            }
        }
    }

    private func loadDetails() async {
        let id = current.id
        do {
            let loaded = try await app.client.movieDetail(streamId: id)
            guard current.id == id else { return }
            info = loaded
            await loadCast(tmdbId: loaded.tmdbId, year: loaded.year, fallback: loaded.cast)
        } catch {
            guard current.id == id else { return }
            detailsFailed = true
            await loadCast(tmdbId: 0, year: parsed.year ?? "", fallback: "")
        }
    }

    /// Headshots by TMDB id, or by title search when the provider sent no id.
    private func loadCast(tmdbId: Int, year: String, fallback: String) async {
        var id = tmdbId
        if id != 0, let exact = await app.tmdb.details(tmdbId: id, isSeries: false) {
            originalLanguage = exact.originalLanguage
            if !exact.overview.isEmpty { englishPlot = exact.overview }
            if !exact.posterUrl.isEmpty { tmdbPoster = exact.posterUrl.replacingOccurrences(of: "/w500/", with: "/w780/") }
            if !exact.backdropUrl.isEmpty { tmdbBackdrop = exact.backdropUrl }
        } else if let hit = await app.tmdb.match(title: parsed.clean, year: year, isSeries: false) {
            id = hit.tmdbId
            originalLanguage = hit.originalLanguage
            if !hit.overview.isEmpty { englishPlot = hit.overview }
            if !hit.posterUrl.isEmpty { tmdbPoster = hit.posterUrl.replacingOccurrences(of: "/w500/", with: "/w780/") }
            if let exact = await app.tmdb.details(tmdbId: hit.tmdbId, isSeries: false), !exact.backdropUrl.isEmpty {
                tmdbBackdrop = exact.backdropUrl
            }
        }
        let members = await app.tmdb.castWithImages(tmdbId: id, isSeries: false)
        cast = members.isEmpty ? CastRow.fallback(fallback) : members
    }

    // MARK: Playback

    private func play(fromStart: Bool) {
        print("UI movie play fromStart=\(fromStart) id=\(current.id)")
        let position = fromStart ? 0 : (mark?.positionMs ?? 0)
        let title = parsed.clean
        let newMark = ResumeStore.Mark(
            key: resumeKey, title: title, poster: posterUrl, kind: .movie,
            entryId: current.id, episodeId: 0, season: 0, episode: 0,
            positionMs: position, durationMs: mark?.durationMs ?? (info?.durationSeconds ?? 0) * 1000, updatedAt: 0)
        app.resume.remember(newMark)
        app.sourceChoices.remember(current)   // playing from this copy makes it the default
        var request = PlayRequest(url: app.client.movieUrl(current), title: title, isLive: false,
                              startMs: max(0, position - 3000), mark: newMark,
                              poster: posterUrl, plot: displayPlot, meta: metaLine)
        request.originalLanguage = originalLanguage
        playing = request
    }
}
