import SwiftUI

/// Lightweight episode browser opened straight from a search result, so every
/// source the search found can be opened on its own instead of collapsing into one
/// series page: title, SOURCES pills, season tabs and the episode strip. No hero,
/// and no source choice is saved until something is actually played. Port of the
/// Android `SearchEpisodesActivity`.
struct SearchEpisodesView: View {
    let entry: Entry
    @EnvironmentObject var app: AppState
    @StateObject private var model: SeriesEpisodesModel
    @State private var playing: PlayRequest?
    @State private var launchedRequestId: UUID?
    @State private var anchorEpisode = -1
    @State private var toast: ToastMessage?

    init(entry: Entry) {
        self.entry = entry
        _model = StateObject(wrappedValue: SeriesEpisodesModel(entry: entry))
    }

    var body: some View {
        ZStack {
            Theme.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Text(model.cleanName).font(.system(size: 40, weight: .bold)).lineLimit(1)
                        PillRow(pills: TitleParser.parse(model.source.name).pills)
                        Spacer()
                    }
                    .padding(.horizontal, 60).padding(.top, 40)
                    if model.info == nil && model.error.isEmpty {
                        Text("Loading \(model.cleanName)...").font(.system(size: 21)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 60)
                    } else if !model.error.isEmpty {
                        Text(model.error).font(.system(size: 21)).foregroundStyle(Theme.accent).padding(.horizontal, 60)
                    }
                    SourcePills(sources: model.sources, selectedId: model.source.id) { source in
                        // Browsing only: the default source is set when you actually play.
                        Task { await model.switchSource(source, app: app) }
                        toast = ToastMessage(text: "Source: \(SourceChoiceStore.pillLabel(source))")
                    }
                    .padding(.horizontal, 60)
                    if !model.seasons.isEmpty {
                        SeasonEpisodeStrip(model: model, anchorEpisode: $anchorEpisode) { play($0) }
                    }
                }
            }
        }
        .overlay(ToastOverlay(toast: $toast))
        // The search row named one specific copy; open exactly that one.
        .task { await model.open(app: app, applySavedChoice: false) }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
    }

    private func play(_ episode: Episode) {
        let request = model.playRequest(for: episode, app: app) { result in
            guard result.requestId == launchedRequestId else { return }
            if model.seasons.contains(result.season) { model.selectedSeason = result.season }
            anchorEpisode = result.episode
        }
        launchedRequestId = request.id
        playing = request
    }
}
