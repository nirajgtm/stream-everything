import SwiftUI

/// Live TV: a left navigator (Favorites, languages by usage, then cross-cutting
/// smart lists), type chips and a search box on top, channel rows with logos and
/// EPG on the right, and a live preview of the focused channel after a short dwell.
/// Replaces the functionality of the plain `LiveView` grid.
struct LiveBrowseView: View {
    /// Language bucket to open on, e.g. a tile on the home rail. nil picks the last
    /// watched channel's language, else the biggest language.
    var startLanguage: String? = nil
    /// Open on the Favorites list.
    var startFavorites = false

    @EnvironmentObject private var app: AppState
    @ObservedObject private var memory = LiveMemory.shared
    @StateObject private var preview = ChannelPreviewController()

    @State private var groups: [LiveBuckets.Group] = []
    @State private var navItems: [NavItem] = []
    @State private var selectedKey = ""
    @State private var selectedType: LiveBuckets.ChannelType?
    @State private var query = ""
    @State private var channels: [Entry] = []
    @State private var shown = 0
    @State private var archiveIds: Set<Int> = []
    @State private var status = "Loading live channels..."
    @State private var playing: PlayRequest?
    @State private var toast: ToastMessage?
    /// Bumped per refresh so a slow background filter cannot overwrite a newer one.
    @State private var refreshGeneration = 0
    @State private var didOpen = false
    @FocusState private var focusedNavKey: String?
    @FocusState private var focusedChannelId: Int?

    private let pageSize = 100

    /// One row in the left navigator. Languages and smart lists share one flat list.
    private enum NavItem: Identifiable {
        case favorites(count: Int)
        case language(LiveBuckets.Group)
        case smart(LiveBuckets.SmartList)
        /// Channels taken off the lists with a long press; they can be put back here.
        case removed(count: Int)

        var id: String { navKey }

        /// Stable key for access tracking.
        var navKey: String {
            switch self {
            case .favorites: return "favorites"
            case .language(let group): return "lang:\(group.label)"
            case .smart(let smart): return "smart:\(smart.label)"
            case .removed: return "removed"
            }
        }

        var label: String {
            switch self {
            case .favorites(let count): return "♥ Favorites  (\(count))"
            case .language(let group): return "\(group.label)  (\(group.channels.count))"
            case .smart(let smart): return smart.label
            case .removed(let count): return "Removed  (\(count))"
            }
        }

        /// Alphabetical key with emoji and symbols stripped.
        var sortKey: String {
            switch self {
            case .favorites: return ""
            case .language(let group): return group.label.lowercased()
            case .smart(let smart): return smart.sortKey.lowercased()
            case .removed: return "~"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.callout)
                .foregroundStyle(Color(red: 0.5, green: 0.8, blue: 0.77))
                .padding(.horizontal, 24)
            HStack(alignment: .top, spacing: 24) {
                navigator.frame(width: 420)
                VStack(alignment: .leading, spacing: 12) {
                    filterBar
                    HStack(alignment: .top, spacing: 24) {
                        channelList
                        ChannelPreviewPane(controller: preview).frame(width: 460)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .overlay(ToastOverlay(toast: $toast))
        .navigationTitle("Live TV")
        .task { await openIfNeeded() }
        .onChange(of: focusedNavKey) { _, key in
            // Moving along the navigator previews that list without an explicit click.
            if let key, key != selectedKey { select(key, byClick: false) }
        }
        .onChange(of: focusedChannelId) { _, id in
            guard let id, let channel = channels.first(where: { $0.id == id }) else {
                preview.focusChanged(to: nil, url: nil)
                return
            }
            preview.focusChanged(to: channel, url: app.client.liveUrl(channel))
        }
        .onChange(of: query) { _, _ in refreshChannels() }
        .onChange(of: playing == nil) { _, dismissed in
            // Back from the player: recently opened lists rise and markers refresh.
            if dismissed && didOpen { rebuildNavigator(); refreshChannels() }
        }
        .onDisappear { preview.pause() }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
    }

    // MARK: Pieces

    private var navigator: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(navItems) { item in
                    Button {
                        select(item.navKey, byClick: true)
                    } label: {
                        Text(item.label)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .background(item.navKey == selectedKey ? Color.white.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .focused($focusedNavKey, equals: item.navKey)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search live channels", text: $query)
                .frame(maxWidth: 520)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    chip("All", type: nil)
                    ForEach(LiveBuckets.ChannelType.chips) { type in chip(type.rawValue, type: type) }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func chip(_ label: String, type: LiveBuckets.ChannelType?) -> some View {
        let selected = type == selectedType
        return Button {
            selectedType = type
            refreshChannels()
        } label: {
            Text(label).lineLimit(1).fixedSize()
        }
        .buttonStyle(ChipButtonStyle(selected: selected))
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(channels.prefix(shown)) { channel in
                    ChannelRow(
                        channel: channel,
                        isFavorite: memory.isFavorite(channel.id),
                        played: memory.playCount(channel.id) > 0,
                        hasArchive: archiveIds.contains(channel.id),
                        isRemoved: memory.isRemoved(channel.id),
                        onPlay: { play(channel) },
                        onToggleFavorite: { toggleFavorite(channel) },
                        onToggleRemoved: { toggleRemoved(channel) })
                    .focused($focusedChannelId, equals: channel.id)
                }
                if shown < channels.count {
                    // Reaching the end of a page reveals the next one.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .onAppear { shown = min(shown + pageSize, channels.count) }
                }
                if channels.isEmpty && didOpen {
                    Text(query.isEmpty ? "No channels here." : "No channels match \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Loading

    /// Groups the catalog once (off the main actor; the result is memoized) and
    /// lands on the requested list, else the last watched channel.
    private func openIfNeeded() async {
        guard !didOpen else { return }
        let live = app.live
        let adultFilter = app.adultFilter
        let grouped = await Task.detached(priority: .userInitiated) {
            LiveBuckets.group(live, adultFilter: adultFilter)
        }.value
        groups = grouped
        archiveIds = await app.client.archiveChannelIds()
        rebuildNavigator()

        let lastChannel = memory.lastChannelId.flatMap { id in live.first { $0.id == id } }
        let startKey: String
        if startFavorites {
            startKey = "favorites"
        } else if let startLanguage,
                  let item = navItems.first(where: { $0.sortKey == startLanguage.lowercased() && $0.navKey.hasPrefix("lang:") }) {
            startKey = item.navKey
        } else if let lastChannel, LiveBuckets.bucket(of: lastChannel.name) != "Other",
                  navItems.contains(where: { $0.navKey == "lang:\(LiveBuckets.bucket(of: lastChannel.name))" }) {
            startKey = "lang:\(LiveBuckets.bucket(of: lastChannel.name))"
        } else {
            // The biggest language group (groups come biggest first); an empty
            // Favorites list or a one-channel group is a dead end to open on.
            // "Other" is the unsorted leftovers; English first, then the biggest real group.
            let english = groups.first { $0.label.hasPrefix("English") }
            let biggest = groups.first { $0.label != "Other" }
            startKey = (english ?? biggest ?? groups.first).map { "lang:\($0.label)" } ?? "favorites"
        }
        didOpen = true
        select(startKey, byClick: false)
        // Land on the last watched channel if it is in this list, else the first row.
        if let lastChannel, channels.contains(where: { $0.id == lastChannel.id }) {
            if let index = channels.firstIndex(where: { $0.id == lastChannel.id }), index >= shown {
                shown = min(channels.count, ((index / pageSize) + 1) * pageSize)
            }
            focusedChannelId = lastChannel.id
        } else {
            focusedChannelId = channels.first?.id
        }
    }

    /// Favorites first, then languages and smart lists as one flat list: recently
    /// opened lists ranked first, the rest alphabetical.
    private func rebuildNavigator() {
        let access = memory.navAccess
        let all: [NavItem] = groups.map { .language($0) } + LiveBuckets.smartLists.map { .smart($0) }
        // Recently opened lists first, then alphabetical; "Other" (unsorted leftovers)
        // always last so a real language is one press away.
        let sorted = all.sorted { lhs, rhs in
            let lOther = lhs.navKey == "lang:Other", rOther = rhs.navKey == "lang:Other"
            if lOther != rOther { return rOther }
            let l = access[lhs.navKey] ?? 0, r = access[rhs.navKey] ?? 0
            return l != r ? l > r : lhs.sortKey < rhs.sortKey
        }
        navItems = [.favorites(count: memory.favorites.count)] + sorted
        if !memory.removed.isEmpty { navItems.append(.removed(count: memory.removed.count)) }
        status = "Live TV  ·  \(groups.count) languages"
    }

    private func select(_ key: String, byClick: Bool) {
        guard navItems.contains(where: { $0.navKey == key }) else { return }
        selectedKey = key
        selectedType = nil
        // Opening a list by click marks it recently accessed (browsing past it does not).
        if byClick && key != "favorites" { memory.touchNav(key) }
        refreshChannels()
        if byClick { focusedChannelId = channels.first?.id }
    }

    /// Resolves the selected list, applies the type chip and search text, and
    /// orders most-played first. Smart lists scan the whole catalog, so they run
    /// off the main actor and are dropped if a newer refresh started meanwhile.
    private func refreshChannels() {
        guard let item = navItems.first(where: { $0.navKey == selectedKey }) else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let type = selectedType
        let words = query.split(separator: " ").map { TitleText.searchKey(String($0)) }.filter { !$0.isEmpty }
        let adultFilter = app.adultFilter
        let live = app.live
        let removed = memory.removedSet
        let showingRemoved = selectedKey == "removed"

        func apply(_ base: [Entry], head: String) {
            guard generation == refreshGeneration else { return }
            // Removed channels stay out of every list but their own.
            var list = showingRemoved ? base : base.filter { !removed.contains($0.id) }
            if let type { list = list.filter { LiveBuckets.ChannelType.of($0.name) == type } }
            if !words.isEmpty { list = list.filter { entry in words.allSatisfy { entry.searchKey.contains($0) } } }
            channels = memory.sortedByPlays(list)
            shown = min(pageSize, channels.count)
            var line = "\(head)  ·  \(channels.count) channels"
            if let type { line += " · \(type.rawValue)" }
            if !words.isEmpty { line += " · search" }
            status = line
            if let focused = focusedChannelId, !channels.prefix(shown).contains(where: { $0.id == focused }) {
                focusedChannelId = didOpen ? channels.first?.id : nil
            }
        }

        // Typing searches the whole live catalog, not just the open list.
        if !words.isEmpty {
            status = "Searching…"
            Task.detached(priority: .userInitiated) {
                let base = live.filter { !(adultFilter && $0.adult) }
                await MainActor.run { apply(base, head: "Search") }
            }
            return
        }

        switch item {
        case .favorites:
            let favorites = memory.favoriteSet
            apply(live.filter { favorites.contains($0.id) && !(adultFilter && $0.adult) }, head: "♥ Favorites")
        case .removed:
            apply(live.filter { removed.contains($0.id) && !(adultFilter && $0.adult) }, head: "Removed")
        case .language(let group):
            apply(group.channels, head: group.label)
        case .smart(let smart):
            status = "\(smart.label)  ·  loading..."
            channels = []
            shown = 0
            Task.detached(priority: .userInitiated) {
                let base = LiveBuckets.channels(in: live, matching: smart, adultFilter: adultFilter)
                await MainActor.run { apply(base, head: smart.label) }
            }
        }
    }

    // MARK: Actions

    /// Off the lists (or back on them); the row disappears from the open list and
    /// focus stays near where it was.
    private func toggleRemoved(_ channel: Entry) {
        let nowRemoved = memory.toggleRemoved(channel.id)
        toast = ToastMessage(text: nowRemoved ? "Removed \(channel.displayTitle). Find it under Removed." : "Put back: \(channel.displayTitle)")
        let index = channels.firstIndex(where: { $0.id == channel.id }) ?? 0
        rebuildNavigator()
        if !navItems.contains(where: { $0.navKey == selectedKey }) { selectedKey = "favorites" }
        refreshChannels()
        if !channels.contains(where: { $0.id == focusedChannelId }) {
            focusedChannelId = channels.isEmpty ? nil : channels[min(index, channels.count - 1)].id
        }
    }

    private func toggleFavorite(_ channel: Entry) {
        let nowFavorite = memory.toggleFavorite(channel.id)
        toast = ToastMessage(text: (nowFavorite ? "Added to" : "Removed from") + " favorites: \(channel.displayTitle)")
        let focused = focusedChannelId
        rebuildNavigator() // keeps the "♥ Favorites (N)" count current
        if selectedKey == "favorites" {
            // Unfavoriting on the Favorites list removes the row; stay near it.
            let index = channels.firstIndex(where: { $0.id == channel.id }) ?? 0
            refreshChannels()
            if !channels.contains(where: { $0.id == focused }) {
                focusedChannelId = channels.isEmpty ? nil : channels[min(index, channels.count - 1)].id
            }
        }
    }

    private func play(_ channel: Entry) {
        preview.pause() // free the decoder before full playback
        memory.recordPlay(channel.id)
        memory.touchLanguage(LiveBuckets.bucket(of: channel.name))
        if selectedKey != "favorites" { memory.touchNav(selectedKey) }
        var request = PlayRequest(url: app.client.liveUrl(channel), title: channel.displayTitle,
                                  isLive: true, startMs: 0, mark: nil)
        // Up/Down in the player walk this list, in the order shown here.
        request.zapList = channels
        request.zapIndex = channels.firstIndex(where: { $0.id == channel.id }) ?? 0
        playing = request
    }
}
