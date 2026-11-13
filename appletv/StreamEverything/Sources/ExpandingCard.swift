import SwiftUI

/// What a card shows when it has been focused for a moment: the poster stays and a
/// panel unfolds beside it with the title, a line of facts and the overview, the way
/// the Google TV app's cards expand. Captions under posters are gone; the panel is
/// where the name lives now.
struct CardDetail: Hashable {
    let title: String
    let meta: String
    let overview: String
    let tmdbId: Int
    let isSeries: Bool
}

struct ExpandingPosterCard: View {
    let imageUrl: String
    let detail: CardDetail
    var progress: Double = 0
    /// Faint band: how much of the file is already on disk.
    var buffered: Double = 0
    var expanded = false
    /// Fetches an overview when the card was built without one (Continue Playing).
    var loadOverview: (() async -> String)? = nil
    @EnvironmentObject var app: AppState
    @State private var cast = ""
    @State private var loadedOverview = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .bottom) {
                Color(white: 0.16)
                CachedImage(url: URL(string: imageUrl)) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                }
                if (progress > 0.01 && progress < 0.99) || buffered > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.45))
                                .frame(width: geo.size.width * min(1, max(progress, buffered)), height: 6)
                            Rectangle().fill(Theme.accent)
                                .frame(width: geo.size.width * min(1, progress), height: 6)
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: 220, height: 320)
            .clipped()
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
                    if !detail.meta.isEmpty { Text(detail.meta).font(.system(size: 17)).foregroundStyle(Theme.accent) }
                    let overview = detail.overview.isEmpty ? loadedOverview : detail.overview
                    Text(overview.isEmpty ? (loadOverview == nil ? "No description available." : "Loading...") : overview)
                        .font(.system(size: 17)).foregroundStyle(Theme.body).lineLimit(8)
                    if !cast.isEmpty { Text("Cast: \(cast)").font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(2) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(width: 440, height: 320, alignment: .topLeading)
                .background(Color(hex: "#1A2029"))
                .task {
                    if detail.overview.isEmpty, loadedOverview.isEmpty, let loadOverview {
                        loadedOverview = await loadOverview()
                    }
                    guard cast.isEmpty, detail.tmdbId != 0 else { return }
                    cast = await app.tmdb.castNames(tmdbId: detail.tmdbId, isSeries: detail.isSeries)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.25), value: expanded)
    }
}

/// Tracks which card in a rail has been focused long enough to expand.
@MainActor
final class CardExpansion: ObservableObject {
    @Published var expandedId: String?
    /// Runs once per dwell, when the card expands; rails use it to prefetch the title.
    var onDwell: ((String) -> Void)?
    private var timer: Task<Void, Never>?

    func focusChanged(to id: String?) {
        timer?.cancel()
        if expandedId != id { expandedId = nil }
        guard let id else { return }
        timer = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            expandedId = id
            onDwell?(id)
        }
    }
}
