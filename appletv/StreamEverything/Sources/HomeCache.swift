import Foundation

/// One resolved card in a saved rail: what to draw plus how to open it.
struct CardData: Codable, Hashable, Identifiable {
    let display: String
    /// The raw catalog name, needed to find other sources of the same title later.
    let name: String
    let kind: Kind
    let entryId: Int
    let ext: String
    let poster: String
    var overview: String = ""
    var tmdbId: Int = 0
    var year: String = ""

    var id: String { "\(kind.rawValue):\(entryId)" }

    // Short keys keep the snapshot small; a few hundred cards are rewritten often.
    enum CodingKeys: String, CodingKey {
        case display = "d", name = "n", kind = "k", entryId = "i", ext = "e", poster = "p"
        case overview = "o", tmdbId = "tid", year = "y"
    }

    init(display: String, name: String, kind: Kind, entryId: Int, ext: String, poster: String,
         overview: String = "", tmdbId: Int = 0, year: String = "") {
        self.display = display
        self.name = name
        self.kind = kind
        self.entryId = entryId
        self.ext = ext
        self.poster = poster
        self.overview = overview
        self.tmdbId = tmdbId
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decode(String.self, forKey: .display)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        entryId = try c.decode(Int.self, forKey: .entryId)
        ext = try c.decode(String.self, forKey: .ext)
        poster = try c.decode(String.self, forKey: .poster)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId) ?? 0
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
    }
}

/// One saved rail. `providerKey` is -1 for rails that are not a provider (Trending).
struct RailData: Codable, Hashable, Identifiable {
    let title: String
    var providerKey: Int = -1
    var logoUrl: String = ""
    let cards: [CardData]

    var id: String { title }

    enum CodingKeys: String, CodingKey {
        case title = "t", providerKey = "pk", logoUrl = "lu", cards
    }

    init(title: String, providerKey: Int = -1, logoUrl: String = "", cards: [CardData]) {
        self.title = title
        self.providerKey = providerKey
        self.logoUrl = logoUrl
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        providerKey = try c.decodeIfPresent(Int.self, forKey: .providerKey) ?? -1
        logoUrl = try c.decodeIfPresent(String.self, forKey: .logoUrl) ?? ""
        cards = try c.decode([CardData].self, forKey: .cards)
    }
}

struct HomeSnapshot: Codable {
    /// Seconds since 1970.
    let savedAt: Double
    let rails: [RailData]
    /// Bumped whenever the way titles are matched to the catalog changes, so a new
    /// build rebuilds the rails instead of showing matches made by the old rules.
    var logicVersion: Int = 0
    static let currentLogicVersion = 2
}

/// Persists the home rails so the app opens to the last known state instantly, then
/// refreshes in the background when the snapshot is older than the caller's TTL.
final class HomeCache {
    private let file: URL

    /// Default file is the main home snapshot; pass another name for a provider hub
    /// (`HomeCache(name: "hub_8")`).
    init(name: String = "home_snapshot") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("\(name).json")
    }

    /// Seconds since the snapshot was saved; infinite when there is none.
    func age(now: Date = Date()) -> TimeInterval {
        guard let snapshot = load(), snapshot.logicVersion == HomeSnapshot.currentLogicVersion else { return .infinity }
        return now.timeIntervalSince1970 - snapshot.savedAt
    }

    func load() -> HomeSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(HomeSnapshot.self, from: data)
    }

    func save(_ snapshot: HomeSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func save(rails: [RailData], now: Date = Date()) {
        save(HomeSnapshot(savedAt: now.timeIntervalSince1970, rails: rails, logicVersion: HomeSnapshot.currentLogicVersion))
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
