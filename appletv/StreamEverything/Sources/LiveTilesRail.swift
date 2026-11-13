import SwiftUI

/// The "Live TV" rail for the home screen: ♥ Favorites (once there are any), All
/// Live, Sports, then the languages the viewer has watched, most recent first. A
/// language tile appears organically after playing a channel of it; a long press
/// hides it again. Embed with `LiveTilesRail()` inside HomeView's NavigationStack.
struct LiveTilesRail: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var memory = LiveMemory.shared
    @State private var toast: ToastMessage?

    private enum Tile: Identifiable {
        case favorites, allLive, sports, language(String)

        var id: String {
            switch self {
            case .favorites: return "favorites"
            case .allLive: return "all"
            case .sports: return "sports"
            case .language(let name): return "lang:\(name)"
            }
        }

        var label: String {
            switch self {
            case .favorites: return "♥ Favorites"
            case .allLive: return "All Live"
            case .sports: return "Sports"
            case .language(let name): return name
            }
        }

        /// Only watched-language tiles can be removed from the rail.
        var removableLanguage: String? {
            if case .language(let name) = self { return name }
            return nil
        }
    }

    private var tiles: [Tile] {
        (memory.favorites.isEmpty ? [] : [.favorites]) + [.allLive, .sports]
            + memory.recentLanguages().map { Tile.language($0) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 24) {
                ForEach(tiles) { tile in
                    NavigationLink {
                        destination(tile)
                    } label: {
                        LiveTileArt(label: tile.label)
                    }
                    .buttonStyle(.card)
                    .contextMenu {
                        if let language = tile.removableLanguage {
                            Button("Remove \(language) from Live TV", role: .destructive) {
                                memory.removeLanguage(language)
                                toast = ToastMessage(text: "Removed \(language) from Live TV")
                            }
                        }
                    }
                    .padding(.top, RailHeader.height)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 20)
            .overlay(alignment: .topLeading) {
                RailHeader(title: "Live TV", detail: "\(app.live.count.formatted()) channels")
            }
        }
        .overlay(ToastOverlay(toast: $toast))
    }

    @ViewBuilder
    private func destination(_ tile: Tile) -> some View {
        switch tile {
        case .favorites: LiveBrowseView(startFavorites: true)
        case .allLive: LiveBrowseView()
        case .sports: SportsView()
        case .language(let name): LiveBrowseView(startLanguage: name)
        }
    }
}

/// A 16:9 tile with the label drawn over a gradient whose hue comes from the label,
/// so the same language always gets the same color without any artwork files.
struct LiveTileArt: View {
    let label: String

    private var hue: Double {
        // A stable hash: Swift's Hasher is seeded per process, which would recolor
        // the tiles on every launch.
        let sum = label.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) & 0xFFFF }
        return Double(sum % 360) / 360
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.45),
                         Color(hue: hue, saturation: 0.7, brightness: 0.25)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: label == "Sports" ? "sportscourt" : "tv")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.18))
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Text(label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(18)
        }
        .frame(width: 360, height: 202)
    }
}
