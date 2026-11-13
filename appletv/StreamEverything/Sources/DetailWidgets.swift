import SwiftUI

/// The colors the Android screens use, so both apps look like one product.
enum Theme {
    static let accent = Color(red: 0.5, green: 0.8, blue: 0.77)        // #80CBC4
    static let page = Color(hex: "#0B0F14")                              // detail pages
    static let chrome = Color(hex: "#101820")                            // home background
    static let chip = Color(hex: "#22303C")
    static let chipFocused = Color(hex: "#3A5064")
    static let muted = Color(hex: "#9FB3C0")
    static let body = Color(hex: "#C7D3DA")
    static let faint = Color(hex: "#8A93A0")
    static let card = Color(hex: "#1A2029")
}

extension Color {
    /// "#RRGGBB" or "#AARRGGBB" (Android order), as the pill palette is written.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst(hex.hasPrefix("#") ? 1 : 0))).scanHexInt64(&value)
        let a, r, g, b: Double
        if hex.count > 7 {
            a = Double((value >> 24) & 0xFF) / 255
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            a = 1
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Routes

/// Every page the home stack can push. One enum so the destination table lives in
/// one place and rails, search and Continue Playing all navigate the same way.
enum AppRoute: Hashable {
    case movie(Entry)
    case series(Entry, focusSeason: Int, focusEpisode: Int)
    case searchEpisodes(Entry)
    case providerHub(Int)
    case settings
    case liveBrowse(language: String?)
    case sports

    static func series(_ entry: Entry) -> AppRoute { .series(entry, focusSeason: -1, focusEpisode: -1) }
}

extension View {
    /// Installs the destinations for `AppRoute`; put it once on the root of the stack.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteView(route: route)
        }
    }
}

private struct AppRouteView: View {
    let route: AppRoute
    @EnvironmentObject var app: AppState

    var body: some View {
        switch route {
        case .movie(let entry):
            MovieView(entry: entry)
        case .series(let entry, let season, let episode):
            SeriesView(entry: entry, focusSeason: season, focusEpisode: episode)
        case .liveBrowse(let language):
            LiveBrowseView(startLanguage: language)
        case .sports:
            SportsView()
        case .searchEpisodes(let entry):
            SearchEpisodesView(entry: entry)
        case .providerHub(let key):
            if let provider = TmdbClient.provider(forKey: key) {
                ProviderHubView(provider: provider)
            } else {
                Text("Unknown provider").foregroundStyle(.secondary)
            }
        case .settings:
            SettingsView(account: app.account, settings: app.settings, onAccountChanged: { app.reloadAfterAccountChange() })
        }
    }
}

// MARK: - Buttons and chips

/// Pill-shaped hero button: white when primary or focused, translucent otherwise,
/// matching the Android `styleHeroButton`.
struct HeroButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        let filled = primary || focused
        configuration.label
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(filled ? Theme.page : .white)
            .padding(.horizontal, 36)
            .padding(.vertical, 16)
            .background(filled ? Color.white : Color.white.opacity(0.2), in: Capsule())
            .scaleEffect(focused ? 1.04 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Filter chip: teal fill when selected, lighter fill plus a white ring when focused.
struct ChipButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.chrome : .white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(selected ? Theme.accent : (focused ? Theme.chipFocused : Theme.chip), in: Capsule())
            .overlay(Capsule().stroke(focused ? Color.white : Color.clear, lineWidth: 3))
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Season tab: white when focused, dark pill when active, faint otherwise.
struct SeasonChipStyle: ButtonStyle {
    var active = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: active ? .bold : .regular))
            .foregroundStyle(focused ? Theme.page : (active ? .white : Theme.faint))
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(focused ? Color.white : (active ? Color(hex: "#2A3540") : Theme.card), in: Capsule())
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

// MARK: - Pills

/// Readable tags after a title: language, quality, network, year, each on its own color.
struct PillRow: View {
    let pills: [Pill]
    var compact = false

    var body: some View {
        if !pills.isEmpty {
            HStack(spacing: compact ? 6 : 10) {
                ForEach(pills, id: \.self) { pill in
                    Text(pill.text)
                        .font(.system(size: compact ? 15 : 18, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 8 : 12)
                        .padding(.vertical, compact ? 2 : 5)
                        .background(Color(hex: pill.color), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// The SOURCES row: one pill per catalog copy of the title, the chosen one filled.
struct SourcePills: View {
    let sources: [Entry]
    let selectedId: Int
    /// A better copy that appeared after the viewer chose a source; gets a badge.
    var upgradeId: Int? = nil
    let onSelect: (Entry) -> Void

    var body: some View {
        if sources.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("SOURCES  (\(sources.count))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .kerning(1.2)
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(sources) { source in
                            Button {
                                onSelect(source)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(SourceChoiceStore.pillLabel(source))
                                    if source.id == upgradeId {
                                        Text("NEW").font(.system(size: 13, weight: .bold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.page)
                                    }
                                }
                            }
                            .buttonStyle(ChipButtonStyle(selected: source.id == selectedId))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: - Cast

/// Apple TV style cast row: circular headshots with name and role, or names only.
struct CastRow: View {
    let members: [TmdbClient.CastMember]

    var body: some View {
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cast").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 28) {
                        ForEach(members) { member in
                            VStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(Theme.chip)
                                    if member.profileUrl.isEmpty {
                                        Image(systemName: "person.fill").font(.system(size: 40)).foregroundStyle(Theme.muted)
                                    } else {
                                        CachedImage(url: URL(string: member.profileUrl)) { phase in
                                            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                                        }
                                    }
                                }
                                .frame(width: 120, height: 120)
                                .clipShape(Circle())
                                Text(member.name).font(.system(size: 18, weight: .medium)).lineLimit(1)
                                if !member.character.isEmpty {
                                    Text(member.character).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }
                            .frame(width: 150)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// Names from the provider's comma list when TMDB has no credits.
    static func fallback(_ names: String) -> [TmdbClient.CastMember] {
        names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { TmdbClient.CastMember(name: $0, character: "", profileUrl: "") }
    }
}

// MARK: - Episode card

/// 16:9 still with a watched bar, "EPISODE n", name, two lines of plot, runtime.
/// TMDB's name/overview/still win over the provider's when present.
struct SeriesEpisodeCard: View {
    let episode: Episode
    let meta: TmdbClient.EpisodeMeta?
    let fraction: Double
    let fallbackImage: String
    let onPlay: () -> Void

    private var name: String {
        if let meta, !meta.name.isEmpty { return meta.name }
        let clean = TitleParser.cleanEpisodeTitle(episode.title)
        return clean.isEmpty ? "Episode \(episode.number)" : clean
    }
    private var plot: String { (meta?.overview.isEmpty == false) ? meta!.overview : episode.plot }
    private var still: String {
        if let meta, !meta.still.isEmpty { return meta.still }
        return episode.still.isEmpty ? fallbackImage : episode.still
    }
    private var runtimeMinutes: Int {
        if let meta, meta.runtimeMinutes > 0 { return meta.runtimeMinutes }
        return episode.durationSeconds / 60
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    Theme.card
                    CachedImage(url: URL(string: still)) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                    }
                    if fraction > 0.02 {
                        GeometryReader { geo in
                            Rectangle().fill(Theme.accent)
                                .frame(width: geo.size.width * min(fraction, 1), height: 8)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .frame(width: 340, height: 191)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Text("EPISODE \(episode.number)")
                    .font(.system(size: 15, weight: .medium)).kerning(1).foregroundStyle(Theme.faint)
                    .padding(.top, 8)
                Text(name).font(.system(size: 22, weight: .bold)).lineLimit(1)
                if !plot.isEmpty {
                    Text(plot).font(.system(size: 17)).foregroundStyle(Color(hex: "#AEB8C2")).lineLimit(2)
                }
                Text(runtimeMinutes > 0 ? "▶  \(runtimeMinutes)m" : "▶  Play")
                    .font(.system(size: 17)).foregroundStyle(Color(hex: "#AEB8C2"))
            }
            .frame(width: 340, alignment: .leading)
        }
        .buttonStyle(.card)
    }
}

/// One tab per season, the active one bold.
struct SeasonChips: View {
    let seasons: [Int]
    @Binding var selected: Int
    @FocusState private var focusedSeason: Int?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(seasons, id: \.self) { season in
                    Button("Season \(season)") { selected = season }
                        .buttonStyle(SeasonChipStyle(active: season == selected))
                        .focused($focusedSeason, equals: season)
                }
            }
            .padding(.horizontal, 60).padding(.vertical, 8)
        }
        // Moving along the tabs switches the strip, so a season is one press away
        // instead of a press plus a click.
        .onChange(of: focusedSeason) { _, season in if let season { selected = season } }
    }
}

// MARK: - TMDB rails

/// A home or hub rail: optional lead logo card that opens the provider hub, then the
/// poster cards. `started` marks movies with a resume point ("▶ " prefix, as Android).
struct TmdbRail: View {
    let rail: RailData
    let startedMovieIds: Set<Int>
    var onLead: (() -> Void)? = nil
    let onCard: (CardData) -> Void

    @EnvironmentObject private var app: AppState
    @StateObject private var expansion = CardExpansion()
    @FocusState private var focusedCard: String?

    private var leadLabel: String? {
        rail.providerKey == -1 ? nil : TmdbClient.provider(forKey: rail.providerKey).map { "\($0.label) ›" }
    }

    var body: some View {
        // The title sits inside the cards' top padding, so when a card is scrolled
        // into view its frame already includes the title and nothing gets cut off.
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 24) {
                if let leadLabel, let onLead {
                    Button(action: onLead) {
                        ProviderLogoCard(label: leadLabel, logoUrl: rail.logoUrl)
                    }
                    .buttonStyle(.card)
                    .padding(.top, RailHeader.height)
                }
                ForEach(rail.cards) { card in
                    Button { onCard(card) } label: {
                        let started = card.kind == .movie && startedMovieIds.contains(card.entryId)
                        ExpandingPosterCard(
                            imageUrl: card.poster,
                            detail: CardDetail(title: card.display,
                                               meta: [card.year, card.kind == .series ? "Series" : "Movie", started ? "Started" : ""]
                                                   .filter { !$0.isEmpty }.joined(separator: "  ·  "),
                                               overview: card.overview, tmdbId: card.tmdbId, isSeries: card.kind == .series),
                            expanded: expansion.expandedId == card.id)
                    }
                    .buttonStyle(.card)
                    .focused($focusedCard, equals: card.id)
                    .padding(.top, RailHeader.height)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 20)
        }
        // On the scroll view, not its content, so the title stays put while cards scroll.
        .overlay(alignment: .topLeading) { RailHeader(title: rail.title).allowsHitTesting(false) }
        .onChange(of: expansion.expandedId) { _, id in
            if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
        }
        }
        .onChange(of: focusedCard) { _, id in expansion.focusChanged(to: id) }
        // No prefetch while browsing these rails: on a one-connection account every
        // title rested on would cost provider connections right before a Play. The
        // detail pages and Continue Playing prefetch instead, where the intent is clear.
    }
}

/// The first card of a provider rail: the service's logo on a dark tile.
struct ProviderLogoCard: View {
    let label: String
    let logoUrl: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.page
                if logoUrl.isEmpty {
                    Text(label).font(.title2.weight(.semibold)).multilineTextAlignment(.center).padding(16)
                } else {
                    CachedImage(url: URL(string: logoUrl)) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit).padding(40) }
                    }
                }
            }
            .frame(width: 220, height: 320)
            .clipped()
            Text(label).font(.caption).lineLimit(2).frame(width: 220, alignment: .leading)
        }
    }
}

/// Dimmed full-bleed backdrop behind a detail page.
struct BackdropLayer: View {
    let url: String

    var body: some View {
        // Sized by the screen, never by the picture: a filled image reports its own
        // (huge) size to the stack, which pushed the page content off screen.
        GeometryReader { geo in
            ZStack {
                Theme.page
                if !url.isEmpty {
                    CachedImage(url: URL(string: url), maxDim: 1920) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(0.3)
                        }
                    }
                    Color(hex: "#D90B0F14")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Time as "1:02:03" or "12:34".
func formatClock(_ ms: Int) -> String {
    let s = ms / 1000
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}


/// Rail title drawn over the cards' top padding (see TmdbRail for why).
struct RailHeader: View {
    static let height: CGFloat = 84
    let title: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.headline).lineLimit(1).fixedSize()
            if !detail.isEmpty { Text(detail).font(.system(size: 22)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, 60).padding(.top, 10)
    }
}


/// Progress under a Play button: teal for what was watched, a faint band for what is
/// already on disk beyond it, so the viewer can see the title is ready to go.
struct WatchedBar: View {
    let watched: Double
    let buffered: Double

    var body: some View {
        if watched > 0.01 || buffered > 0.01 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: geo.size.width * min(1, max(watched, buffered)))
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * min(1, watched))
                }
            }
            .frame(height: 8)
        }
    }
}
