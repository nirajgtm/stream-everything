import SwiftUI

/// Everything a series screen needs: the chosen source, its episodes grouped by
/// season, TMDB enrichment per season, the other sources of the title, and the
/// playlist handed to the player. Shared by `SeriesView` (full page) and
/// `SearchEpisodesView` (season tabs and strip only) so both play identically.
@MainActor
final class SeriesEpisodesModel: ObservableObject {
    /// The copy whose episodes are shown.
    @Published private(set) var source: Entry
    @Published private(set) var info: SeriesInfo?
    @Published private(set) var seasons: [Int] = []
    @Published var selectedSeason = 0
    @Published private(set) var error = ""
    @Published private(set) var sources: [Entry] = []
    @Published private(set) var cast: [TmdbClient.CastMember] = []
    /// TMDB episode names/stills/plots, keyed by season then episode number.
    @Published private(set) var metaBySeason: [Int: [Int: TmdbClient.EpisodeMeta]] = [:]
    private var tmdbId = 0

    init(entry: Entry) {
        source = entry
    }

    var cleanName: String { TitleParser.parse(source.name).clean }
    var episodes: [Episode] { info?.episodes ?? [] }
    var currentEpisodes: [Episode] { episodes.filter { $0.season == selectedSeason } }
    func meta(for episode: Episode) -> TmdbClient.EpisodeMeta? { metaBySeason[episode.season]?[episode.number] }

    var metaLine: String {
        guard let info else { return "" }
        return [info.genre, info.year, info.rating.isEmpty ? "" : "★ \(info.rating)"]
            .filter { !$0.isEmpty }.joined(separator: "   •   ")
    }

    /// Series poster: the detail cover first, the catalog cover as fallback.
    var cover: String { (info?.cover.isEmpty == false) ? info!.cover : source.logo }
    /// TMDB's backdrop first (full size); provider backdrops are often tiny.
    var backdrop: String {
        if let tmdbBackdrop, !tmdbBackdrop.isEmpty { return tmdbBackdrop }
        return (info?.backdrop.isEmpty == false) ? info!.backdrop : cover
    }
    @Published var tmdbBackdrop: String?

    // MARK: Loading

    /// Find every copy of the title and open the saved or English one, unless the caller
    /// (the source picker) already chose a specific copy.
    func open(app: AppState, applySavedChoice: Bool) async {
        var found = app.sourcesFor(name: source.name, isSeries: true)
        if !found.contains(where: { $0.id == source.id }) { found.insert(source, at: 0) }
        sources = SourceChoiceStore.englishFirst(found)
        if applySavedChoice {
            source = app.sourceChoices.preferred(among: sources, fallback: source)
        }
        await load(app: app, preferSeason: -1)
    }

    /// Browse a different copy. Nothing is saved until an episode is played.
    func switchSource(_ entry: Entry, app: AppState) async {
        guard entry.id != source.id else { return }
        let previous = episodes
        app.sourceChoices.remember(entry, explicit: true)
        source = entry
        info = nil; seasons = []; metaBySeason = [:]; cast = []; error = ""; tmdbBackdrop = nil
        await load(app: app, preferSeason: -1)
        guard source.id == entry.id else { return }
        // Same episodes on the other copy keep their place (matched by season and
        // number, lengths within tolerance).
        for episode in episodes {
            guard let old = previous.first(where: { $0.season == episode.season && $0.number == episode.number }),
                  let mark = app.resume.mark(for: ResumeStore.episodeKey(old.id)) else { continue }
            app.resume.carry(mark, toKey: ResumeStore.episodeKey(episode.id), entryId: source.id, episodeId: episode.id,
                             targetDurationMs: episode.durationSeconds * 1000, ext: episode.ext)
        }
    }

    /// English overview from TMDB, preferred over the provider's text.
    @Published var englishPlot: String?
    /// TMDB's poster at w780, sharper than most provider covers.
    @Published var tmdbPoster: String?
    /// From TMDB; drives the default audio track.
    @Published var originalLanguage = ""
    var displayPlot: String { englishPlot ?? info?.plot ?? "" }

    private func load(app: AppState, preferSeason: Int) async {
        let id = source.id
        do {
            let loaded = try await app.client.seriesDetail(seriesId: id)
            guard source.id == id else { return }
            info = loaded
            seasons = loaded.seasons
            if seasons.isEmpty {
                error = "No episodes on this source, try another source"
                return
            }
            if preferSeason >= 0, seasons.contains(preferSeason) {
                selectedSeason = preferSeason
            } else if let last = app.resume.lastEpisode(seriesId: id), seasons.contains(last.season) {
                selectedSeason = last.season
            } else {
                selectedSeason = seasons[0]
            }
            tmdbId = loaded.tmdbId
            // TMDB's overview is in English; the provider's is in whatever language the
            // copy was tagged with, so it wins whenever TMDB knows the title.
            if tmdbId != 0, let exact = await app.tmdb.details(tmdbId: tmdbId, isSeries: true) {
                originalLanguage = exact.originalLanguage
                if !exact.overview.isEmpty { englishPlot = exact.overview }
                if !exact.posterUrl.isEmpty { tmdbPoster = exact.posterUrl.replacingOccurrences(of: "/w500/", with: "/w780/") }
                if !exact.backdropUrl.isEmpty { tmdbBackdrop = exact.backdropUrl }
            } else if let hit = await app.tmdb.match(title: cleanName, year: loaded.year, isSeries: true) {
                tmdbId = hit.tmdbId
                originalLanguage = hit.originalLanguage
                if !hit.overview.isEmpty { englishPlot = hit.overview }
                if !hit.posterUrl.isEmpty { tmdbPoster = hit.posterUrl.replacingOccurrences(of: "/w500/", with: "/w780/") }
                if let exact = await app.tmdb.details(tmdbId: hit.tmdbId, isSeries: true), !exact.backdropUrl.isEmpty {
                    tmdbBackdrop = exact.backdropUrl
                }
            }
            await enrichSeason(selectedSeason, app: app)
            let members = await app.tmdb.castWithImages(tmdbId: tmdbId, isSeries: true)
            cast = members.isEmpty ? CastRow.fallback(loaded.cast) : members
        } catch {
            guard source.id == id else { return }
            self.error = "Could not load episodes: \(error.localizedDescription)"
        }
    }

    /// Real names, overviews and stills for one season; provider data shows meanwhile.
    func enrichSeason(_ season: Int, app: AppState) async {
        guard tmdbId != 0, metaBySeason[season] == nil else { return }
        let meta = await app.tmdb.seasonEpisodes(tmdbId: tmdbId, season: season)
        if !meta.isEmpty { metaBySeason[season] = meta }
    }

    // MARK: Resume logic

    func fraction(of episode: Episode, app: AppState) -> Double {
        app.resume.mark(for: ResumeStore.episodeKey(episode.id))?.fraction ?? 0
    }

    /// The episode the Play button launches: the one in progress (or the next one when
    /// that is within two minutes of the end), else the very first episode.
    func heroEpisode(app: AppState) -> Episode? {
        let all = episodes
        let marked = all.compactMap { episode -> (Episode, ResumeStore.Mark)? in
            guard let mark = app.resume.mark(for: ResumeStore.episodeKey(episode.id)) else { return nil }
            return (episode, mark)
        }
        guard let (inProgress, mark) = marked.max(by: { $0.1.updatedAt < $1.1.updatedAt }) else { return all.first }
        let nearlyDone = mark.finished || (mark.durationMs > 0 && mark.durationMs - mark.positionMs < 120_000)
        if nearlyDone, let index = all.firstIndex(where: { $0.id == inProgress.id }), index + 1 < all.count {
            return all[index + 1]
        }
        return inProgress
    }

    /// Play button text, as the Android hero words it.
    func playLabel(app: AppState) -> String {
        guard let target = heroEpisode(app: app) else { return "▶  Play" }
        let key = ResumeStore.episodeKey(target.id)
        if let mark = app.resume.mark(for: key), !mark.finished, mark.positionMs > 0 {
            return "▶  Resume S\(target.season) E\(target.number)"
        }
        return "▶  Play S\(target.season) E\(target.number)"
    }

    // MARK: Playback

    /// Overlay title, "Show · S1 E4".
    func label(for episode: Episode) -> String { "\(cleanName) · S\(episode.season) E\(episode.number)" }

    private func episodeName(_ episode: Episode) -> String {
        if let meta = meta(for: episode), !meta.name.isEmpty { return meta.name }
        let clean = TitleParser.cleanEpisodeTitle(episode.title)
        return clean.isEmpty ? "Episode \(episode.number)" : clean
    }

    private func mark(for episode: Episode, app: AppState) -> ResumeStore.Mark {
        let key = ResumeStore.episodeKey(episode.id)
        let existing = app.resume.mark(for: key)
        let position = (existing?.finished == false) ? (existing?.positionMs ?? 0) : 0
        return ResumeStore.Mark(
            key: key, title: label(for: episode), poster: cover, kind: .series,
            entryId: source.id, episodeId: episode.id, season: episode.season, episode: episode.number,
            positionMs: position, durationMs: existing?.durationMs ?? episode.durationSeconds * 1000, updatedAt: 0,
            ext: episode.ext)
    }

    /// The request for `episode` with the whole series (every season, in order) as the
    /// playlist, so the player can step forward and back across season boundaries.
    func playRequest(for episode: Episode, app: AppState, onReturn: @escaping (PlaybackReturn) -> Void) -> PlayRequest {
        let all = episodes
        let playlist = all.map { item in
            PlaylistEpisode(url: app.client.episodeUrl(item), title: label(for: item), episodeTitle: episodeName(item),
                            season: item.season, number: item.number,
                            plot: meta(for: item)?.overview.isEmpty == false ? meta(for: item)!.overview : item.plot,
                            image: meta(for: item)?.still.isEmpty == false ? meta(for: item)!.still : (item.still.isEmpty ? cover : item.still),
                            mark: mark(for: item, app: app))
        }
        let startIndex = all.firstIndex { $0.id == episode.id } ?? 0
        let startMark = mark(for: episode, app: app)
        app.resume.remember(startMark)
        app.sourceChoices.remember(source)   // playing from this copy makes it the default
        var request = PlayRequest(url: app.client.episodeUrl(episode), title: label(for: episode), isLive: false,
                                  startMs: max(0, startMark.positionMs - 3000), mark: startMark,
                                  poster: cover, plot: displayPlot, meta: metaLine,
                                  playlist: playlist, startIndex: startIndex, onReturn: onReturn)
        request.originalLanguage = originalLanguage
        return request
    }
}

/// Season tabs plus the horizontal episode strip, with TMDB enrichment and the
/// return-from-player anchoring both series screens share.
struct SeasonEpisodeStrip: View {
    @ObservedObject var model: SeriesEpisodesModel
    @EnvironmentObject var app: AppState
    /// Episode number to scroll to and focus after returning from the player.
    @Binding var anchorEpisode: Int
    let onPlay: (Episode) -> Void
    @FocusState private var focusedEpisode: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SeasonChips(seasons: model.seasons, selected: $model.selectedSeason)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(model.currentEpisodes) { episode in
                            SeriesEpisodeCard(episode: episode, meta: model.meta(for: episode),
                                        fraction: model.fraction(of: episode, app: app),
                                        fallbackImage: model.cover) { onPlay(episode) }
                                .focused($focusedEpisode, equals: episode.id)
                                .id(episode.id)
                        }
                    }
                    .padding(.horizontal, 60).padding(.vertical, 24)
                }
                .onAppear { applyAnchor(proxy) }
                .onChange(of: anchorEpisode) { _, _ in applyAnchor(proxy) }
                // The strip was rebuilt (season or source switch): re-apply a pending
                // anchor now that the target card exists.
                .onChange(of: model.currentEpisodes.map(\.id)) { _, _ in applyAnchor(proxy) }
            }
        }
        .task(id: model.selectedSeason) { await model.enrichSeason(model.selectedSeason, app: app) }
    }

    /// Scroll to and focus the anchored episode when it is in the visible season, then
    /// clear the anchor so a later season switch does not jump back to it.
    private func applyAnchor(_ proxy: ScrollViewProxy) {
        guard anchorEpisode >= 0,
              let target = model.currentEpisodes.first(where: { $0.number == anchorEpisode }) else { return }
        withAnimation { proxy.scrollTo(target.id, anchor: .leading) }
        focusedEpisode = target.id
        anchorEpisode = -1
    }
}
