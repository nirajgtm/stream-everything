import SwiftUI

/// Full-bleed series page: backdrop hero with title, plot, meta, cast, the
/// Play / Resume button with its watched bar and the SOURCES picker; below it the
/// season tabs and the episode strip with TMDB stills. Port of the Android
/// `MainActivity` series mode (Mode.SERIES), pushed here as its own destination.
struct SeriesView: View {
    let entry: Entry
    /// Season/episode to land on when opened from Continue Playing; -1 for none.
    var focusSeason = -1
    var focusEpisode = -1

    @EnvironmentObject var app: AppState
    @StateObject private var model: SeriesEpisodesModel
    @State private var playing: PlayRequest?
    @State private var launchedRequestId: UUID?
    @State private var anchorEpisode = -1
    @State private var toast: ToastMessage?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case play }

    init(entry: Entry, focusSeason: Int = -1, focusEpisode: Int = -1) {
        self.entry = entry
        self.focusSeason = focusSeason
        self.focusEpisode = focusEpisode
        _model = StateObject(wrappedValue: SeriesEpisodesModel(entry: entry))
    }

    private var heroMark: ResumeStore.Mark? {
        guard let target = model.heroEpisode(app: app) else { return nil }
        return app.resume.mark(for: ResumeStore.episodeKey(target.id))
    }

    var body: some View {
        ZStack {
            Theme.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    if !model.seasons.isEmpty {
                        SeasonEpisodeStrip(model: model, anchorEpisode: $anchorEpisode) { play($0) }
                    }
                    CastRow(members: model.cast).padding(.horizontal, 60).padding(.vertical, 20)
                }
            }
        }
        .overlay(ToastOverlay(toast: $toast))
        .task {
            NSLog("UI series page %@ id=%d", entry.name, entry.id)
            await model.open(app: app, applySavedChoice: true)
            NSLog("UI series seasons=%d error=%@", model.seasons.count, model.error)
            if focusSeason >= 0, model.seasons.contains(focusSeason) { model.selectedSeason = focusSeason }
            if focusEpisode >= 0 { anchorEpisode = focusEpisode }
            // The page opens on Play / Resume whatever loaded last.
            if focusEpisode < 0 { try? await Task.sleep(nanoseconds: 150_000_000); focus = .play }
            // Pull in the episode Play would start, from its resume point.
            if let episode = model.heroEpisode(app: app) {
                let mark = app.resume.mark(for: ResumeStore.episodeKey(episode.id))
                app.prefetch(app.client.episodeUrl(episode), fromFraction: mark?.fraction ?? 0)
            }
        }
        // The seasons and episode cards arrive with the detail response and pull focus
        // with them; put it on Play the moment they land (before cast and TMDB finish).
        .onChange(of: model.seasons.isEmpty) { _, empty in
            guard !empty, focusEpisode < 0 else { return }
            Task { try? await Task.sleep(nanoseconds: 120_000_000); focus = .play }
        }
        // Source pills arriving later must not steal the highlight from Play.
        .onChange(of: model.sources.count) { _, _ in
            guard focusEpisode < 0, focus == nil || focus == .play else { return }
            Task { try? await Task.sleep(nanoseconds: 120_000_000); focus = .play }
        }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // The backdrop fills whatever height the hero text needs (at least 560pt),
            // fading into the page color so the text and the strip below stay readable.
            GeometryReader { geo in
                CachedImage(url: URL(string: model.backdrop), maxDim: 1920) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .opacity(model.info == nil ? 0.35 : 1)   // the cover stands in until the backdrop arrives
                    }
                }
            }
            LinearGradient(colors: [Theme.page.opacity(0), Theme.page.opacity(0.7), Theme.page],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.cleanName).font(.system(size: 50, weight: .bold)).kerning(1).lineLimit(2)
                    PillRow(pills: TitleParser.parse(model.source.name).pills)
                    if !model.displayPlot.isEmpty {
                        Text(model.displayPlot).font(.system(size: 21)).foregroundStyle(Theme.body).lineLimit(2)
                    } else if model.info == nil && model.error.isEmpty {
                        Text("Loading \(model.cleanName)...").font(.system(size: 21)).foregroundStyle(Theme.accent)
                    }
                    if !model.metaLine.isEmpty {
                        Text(model.metaLine).font(.system(size: 19)).foregroundStyle(Theme.muted)
                    }
                    if !model.error.isEmpty { Text(model.error).font(.system(size: 21)).foregroundStyle(.red) }
                    HStack(spacing: 20) {
                        Button(model.playLabel(app: app)) { playHero() }
                            .buttonStyle(HeroButtonStyle(primary: true))
                            .focused($focus, equals: .play)
                            .disabled(model.episodes.isEmpty)
                    }
                    .padding(.top, 8)
                    // Full width as a focus section, so Up from any source pill (they
                    // run far to the right of the button) lands on Play.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                    WatchedBar(watched: heroMark.map { $0.durationMs > 0 ? min($0.fraction, 1) : 0 } ?? 0,
                               buffered: model.heroEpisode(app: app).map { app.prefetchedFraction(of: app.client.episodeUrl($0)) ?? 0 } ?? 0)
                        .frame(width: 360)
                    SourcePills(sources: model.sources, selectedId: model.source.id,
                                upgradeId: app.sourceChoices.upgradeHint(among: model.sources, for: entry)?.id) { source in
                        Task { await model.switchSource(source, app: app) }
                        toast = ToastMessage(text: "Source: \(SourceChoiceStore.pillLabel(source))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let info = model.info, !info.cast.isEmpty {
                    Text("Starring \(info.cast)")
                        .font(.system(size: 19)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.trailing).lineLimit(3)
                        .frame(width: 440, alignment: .bottomTrailing)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 24).padding(.top, 120)
            .frame(maxWidth: .infinity, minHeight: 560, alignment: .bottomLeading)
        }
        // The hero's height comes from its text, never from the image: before the
        // detail response the only art is the portrait cover, and letting it set the
        // height pushed the title and Play button off the bottom of the screen.
        .frame(maxWidth: .infinity, minHeight: 560, maxHeight: 700)
        .clipped()
        .defaultFocus($focus, .play)
    }

    // MARK: Playback

    private func playHero() {
        guard let target = model.heroEpisode(app: app) else { return }
        play(target)
    }

    private func play(_ episode: Episode) {
        let request = model.playRequest(for: episode, app: app) { result in
            // Land back on the episode that was actually on screen, which may differ from
            // the one launched after "Up next" or the episode strip inside the player.
            guard result.requestId == launchedRequestId else { return }
            if model.seasons.contains(result.season) { model.selectedSeason = result.season }
            anchorEpisode = result.episode
        }
        launchedRequestId = request.id
        playing = request
    }
}
