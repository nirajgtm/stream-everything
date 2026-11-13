import SwiftUI

/// Sports & Live Events: the provider's sport/PPV/event categories on the left,
/// their channels on the right (most watched first) with now/next from the EPG,
/// and a live preview of the focused channel.
struct SportsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var memory = LiveMemory.shared
    @StateObject private var preview = ChannelPreviewController()

    @State private var categories: [ChannelCategory] = []
    @State private var selectedCategoryId: String?
    @State private var channels: [Entry] = []
    @State private var archiveIds: Set<Int> = []
    @State private var status = "Loading sports & events…"
    @State private var playing: PlayRequest?
    @State private var toast: ToastMessage?
    @FocusState private var focusedCategoryId: String?
    @FocusState private var focusedChannelId: Int?

    /// A provider category counts as sports when its name carries any of these.
    private static let keywords = [
        "sport", "ppv", "event", "football", "soccer", "nba", "nfl", "nhl", "mlb", "ufc", "mma",
        "f1", "formula", "motogp", "cricket", "tennis", "golf", "boxing", "wwe", "wrestl", "fight",
        "league", "liga", "ligue", "serie a", "bundesliga", "dazn", "espn", "bein", "tnt sport",
        "sky sport", "rugby", "darts", "racing", "uefa", "epl", "premier", "champions", "match", "live "
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.callout)
                .foregroundStyle(Color(red: 0.5, green: 0.8, blue: 0.77))
                .padding(.horizontal, 24)
            HStack(alignment: .top, spacing: 24) {
                categoryList.frame(width: 520)
                channelList
                ChannelPreviewPane(controller: preview).frame(width: 460)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .overlay(ToastOverlay(toast: $toast))
        .navigationTitle("Sports & Live Events")
        .task { await load() }
        .onChange(of: focusedCategoryId) { _, id in
            if let id, id != selectedCategoryId { select(id, byClick: false) }
        }
        .onChange(of: focusedChannelId) { _, id in
            guard let id, let channel = channels.first(where: { $0.id == id }) else {
                preview.focusChanged(to: nil, url: nil)
                return
            }
            preview.focusChanged(to: channel, url: app.client.liveUrl(channel))
        }
        .onChange(of: playing == nil) { _, dismissed in
            if dismissed, let selectedCategoryId { select(selectedCategoryId, byClick: false) }
        }
        .onDisappear { preview.pause() }
        .fullScreenCover(item: $playing) { request in
            PlayerScreen(request: request).environmentObject(app)
        }
    }

    // MARK: Pieces

    private var categoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(categories) { category in
                    Button {
                        select(category.id, byClick: true)
                    } label: {
                        Text(Self.cleanCategoryName(category.name))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .background(category.id == selectedCategoryId ? Color.white.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .focused($focusedCategoryId, equals: category.id)
                }
                if categories.isEmpty && status.hasPrefix("Sports") {
                    Text("The provider lists no sports categories.").foregroundStyle(.secondary).padding()
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(channels) { channel in
                    ChannelRow(
                        channel: channel,
                        isFavorite: memory.isFavorite(channel.id),
                        played: memory.playCount(channel.id) > 0,
                        hasArchive: archiveIds.contains(channel.id),
                        onPlay: { play(channel) },
                        onToggleFavorite: { toggleFavorite(channel) })
                    .focused($focusedChannelId, equals: channel.id)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Loading

    private func load() async {
        let all = (try? await app.client.categories(.live)) ?? []
        categories = all.filter { category in
            let lower = category.name.lowercased()
            return Self.keywords.contains { lower.contains($0) }
        }
        archiveIds = await app.client.archiveChannelIds()
        status = "Sports & Live Events  ·  \(categories.count) categories"
        if let first = categories.first {
            select(first.id, byClick: false)
            focusedCategoryId = first.id
        }
    }

    /// Channels of a provider category come from the loaded live catalog (the
    /// Android app fetched them per category; here the whole list is already in RAM).
    private func select(_ categoryId: String, byClick: Bool) {
        selectedCategoryId = categoryId
        let adultFilter = app.adultFilter
        let list = app.live.filter { $0.categoryId == categoryId && !(adultFilter && $0.adult) }
        channels = memory.sortedByPlays(list)
        if byClick { focusedChannelId = channels.first?.id }
    }

    // MARK: Actions

    private func toggleFavorite(_ channel: Entry) {
        let nowFavorite = memory.toggleFavorite(channel.id)
        toast = ToastMessage(text: (nowFavorite ? "Added to" : "Removed from") + " favorites: \(channel.displayTitle)")
    }

    private func play(_ channel: Entry) {
        preview.pause()
        memory.recordPlay(channel.id)
        memory.touchLanguage(LiveBuckets.bucket(of: channel.name))
        var request = PlayRequest(url: app.client.liveUrl(channel), title: channel.displayTitle,
                                  isLive: true, startMs: 0, mark: nil)
        request.zapList = channels
        request.zapIndex = channels.firstIndex(where: { $0.id == channel.id }) ?? 0
        playing = request
    }

    // MARK: Names

    private static let superscriptMarks: [(String, String)] = [
        ("ᵁᴴᴰ", "UHD"), ("ᴴᴰ", "HD"), ("ᴿᴬᵂ", "RAW"), ("ⱽᴵᴾ", "VIP"),
        ("ˢᴰ", "SD"), ("ᴰᴼᴸᴮʸ", "Dolby"), ("ᴬᵁᴰᴵᴼ", "Audio"), ("ᴷ", "K")
    ]
    private static let leftoverSuperscripts = try! NSRegularExpression(
        pattern: "[\\u02B0-\\u02FF\\u1D2C-\\u1D6A\\u2070-\\u209F\\u1DA0-\\u1DBF³⁸⁴⁰ᴾ]")
    private static let repeatedSpaces = try! NSRegularExpression(pattern: "\\s{2,}")

    /// Drops the "XX|" region prefix and maps superscript quality marks ("ᴴᴰ") to
    /// plain ASCII so category names read normally on a TV.
    static func cleanCategoryName(_ name: String) -> String {
        var text = name
        if let bar = text.firstIndex(of: "|") { text = String(text[text.index(after: bar)...]) }
        text = text.trimmingCharacters(in: .whitespaces)
        for (mark, replacement) in superscriptMarks { text = text.replacingOccurrences(of: mark, with: replacement) }
        text = leftoverSuperscripts.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = repeatedSpaces.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " |-"))
    }
}
