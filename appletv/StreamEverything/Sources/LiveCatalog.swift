import Foundation

/// Coarse live-channel type detected from keywords in the channel name.
enum LiveCategory: String, CaseIterable, Identifiable {
    case sports, news, movies, kids, music, docs, general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sports: return "Sports"
        case .news: return "News"
        case .movies: return "Movies"
        case .kids: return "Kids"
        case .music: return "Music"
        case .docs: return "Docs"
        case .general: return "General"
        }
    }

    var keywords: [String] {
        switch self {
        case .sports: return ["SPORT", "SOCCER", "FOOTBALL", "NBA", "NFL", "UFC", "F1",
                              "CRICKET", "GOLF", "TENNIS", "RUGBY", "BOXING", "HOCKEY", "BASEBALL"]
        case .news: return ["NEWS", "CNN", "BBC", "FOX", "ALJAZEERA"]
        case .movies: return ["CINEMA", "MOVIE", "FILM"]
        case .kids: return ["KIDS", "CARTOON", "DISNEY", "NICK", "BABY"]
        case .music: return ["MUSIC", "MTV", "RADIO", "HITS"]
        case .docs: return ["DOCU", " DOC", "HISTORY", "NATURE", "DISCOVERY", "NAT GEO", "GEO"]
        case .general: return []
        }
    }

    /// First category whose keywords appear in the name; `.general` when none do.
    static func of(_ name: String) -> LiveCategory {
        let upper = name.uppercased()
        for category in [LiveCategory.sports, .news, .movies, .kids, .music, .docs]
        where category.keywords.contains(where: { upper.contains($0) }) {
            return category
        }
        return .general
    }
}

/// Buckets live channels into language groups from their region-code prefix
/// (US:/UK:/IN:/NP:/...), and offers tag-based smart lists (News, Soccer, Kids...)
/// that cut across languages. Adult channels are hidden from every list while the
/// filter is on, both by title and by the provider's own adult categories.
///
/// How a Live TV screen uses it:
///  1. `LiveCatalog.shared.adultFilterOn = app.adultFilter` whenever the setting changes.
///  2. `LiveCatalog.shared.markAdultCategories(from: allCategories)` once the live
///     categories are loaded (use `XtreamClient.liveCategoriesIncludingAdult()` so the
///     adult ones are actually present to be marked).
///  3. Left column: `groups(from: app.live)` for language buckets (biggest first,
///     "Other" last) plus `LiveCatalog.smartLists` for the cross-language lists.
///  4. Right grid: a group's `channels`, or `channels(matching:from:)` for a smart list.
///  5. `bucketOf(name)` gives the language label of a single channel (for "recently
///     watched language" ordering).
final class LiveCatalog {
    static let shared = LiveCatalog()

    /// One language bucket and the channels in it.
    struct Group: Identifiable, Hashable {
        let label: String
        let channels: [Entry]
        var id: String { label }
        var count: Int { channels.count }
    }

    /// A tag-based list that cuts across languages; a channel can match several.
    struct SmartList: Identifiable, Hashable {
        let label: String
        let keys: [String]
        var id: String { label }

        func matches(upperName: String) -> Bool { keys.contains { upperName.contains($0) } }
    }

    static let smartLists: [SmartList] = [
        SmartList(label: "Live Events", keys: ["EVENT"]),
        SmartList(label: "PPV", keys: ["PPV"]),
        SmartList(label: "24/7 Movies & Series", keys: ["24/7", "24-7"]),
        SmartList(label: "News", keys: ["NEWS", "CNN", "ALJAZEERA", "AL JAZEERA", "MSNBC",
                                         "EURONEWS", "SKY NEWS", "FOX NEWS", "GB NEWS", "CNBC", "BLOOMBERG"]),
        SmartList(label: "Movies", keys: ["CINEMA", "MOVIE", " FILM", "CINE ", "PELICULA"]),
        SmartList(label: "Documentary", keys: ["DOCU", " DOC ", "HISTORY", "DISCOVERY",
                                                "NAT GEO", "NATGEO", "NATURE", "ANIMAL PLANET"]),
        SmartList(label: "Kids", keys: ["KIDS", "DISNEY", "NICK", "BABY", "JUNIOR"]),
        SmartList(label: "Anime", keys: ["ANIME", "CRUNCHYROLL", "TOONAMI", "MANGA"]),
        SmartList(label: "Animation", keys: ["ANIMATION", "CARTOON", "ANIMATED", "TOONS"]),
        SmartList(label: "Music", keys: ["MUSIC", "MTV", "VEVO", " HITS", "RADIO"]),
        SmartList(label: "Soccer", keys: ["SOCCER", "FOOTBALL", "FUTBOL", "CALCIO", " LIGA",
                                           "LALIGA", "PREMIER LEAGUE", "UEFA", "CHAMPIONS LEAGUE", "EUROPA", "SERIE A",
                                           "BUNDESLIGA", "LIGUE 1", "EREDIVISIE", "MLS", "EPL", "FA CUP", "CONMEBOL"]),
        SmartList(label: "Basketball", keys: ["BASKETBALL", "NBA", "EUROLEAGUE"]),
        SmartList(label: "American Football", keys: ["NFL", "AMERICAN FOOTBALL", "SUPER BOWL"]),
        SmartList(label: "Boxing & MMA", keys: ["BOXING", "UFC", " MMA", "BELLATOR", "WBC", " FIGHT"]),
        SmartList(label: "Wrestling", keys: ["WWE", "WRESTL", "AEW", " NXT"]),
        SmartList(label: "Cricket", keys: ["CRICKET", " IPL", " BBL", " PSL", " T20"]),
        SmartList(label: "Tennis", keys: ["TENNIS", " ATP", " WTA", "WIMBLEDON", "ROLAND"]),
        SmartList(label: "Golf", keys: ["GOLF", " PGA", "RYDER"]),
        SmartList(label: "Motorsport", keys: ["FORMULA", "MOTOGP", "NASCAR", "RACING", "MOTORSPORT", " F1"]),
        SmartList(label: "Hockey", keys: ["HOCKEY", " NHL"]),
        SmartList(label: "Baseball", keys: ["BASEBALL", " MLB"])
    ]

    // MARK: Region prefix -> language bucket

    /// Region code -> bucket label. Several regions share one bucket where that
    /// reads better (US/USA both "English US"); English is split by region because a
    /// single "English" bucket was too big to navigate.
    private static let regionToBucket: [String: String] = {
        var map: [String: String] = [
            "US": "English US", "USA": "English US",
            "UK": "English UK", "GB": "English UK", "IE": "English UK",
            "CA": "English CA",
            "AU": "English AU/NZ", "NZ": "English AU/NZ",
            "EN": "English",
            "AR": "Arabic", "FR": "French", "DE": "German", "IT": "Italian",
            "TR": "Turkish", "NL": "Dutch", "ES": "Spanish", "GR": "Greek",
            "AL": "Albanian", "BE": "Belgian", "SE": "Swedish", "IR": "Persian",
            "IL": "Hebrew", "RU": "Russian", "HR": "Croatian", "BG": "Bulgarian",
            "DK": "Danish", "PH": "Filipino", "NO": "Norwegian", "BR": "Brazilian",
            "RS": "Serbian", "FI": "Finnish", "PT": "Portuguese", "CZ": "Czech",
            "MX": "Mexican", "PL": "Polish", "RO": "Romanian", "HU": "Hungarian",
            "UA": "Ukrainian", "VN": "Vietnamese", "TH": "Thai", "ID": "Indonesian",
            "MY": "Malay", "KR": "Korean", "JP": "Japanese", "CN": "Chinese",
            "PK": "Pakistani", "BD": "Bengali", "LK": "Sri Lankan", "EG": "Egyptian",
            "MA": "Moroccan", "AT": "Austrian", "CH": "Swiss",
            // Indian languages that carry their own prefix.
            "TAMIL": "Tamil", "TELUGU": "Telugu", "MARATHI": "Marathi", "GUJARATI": "Gujarati",
            "PUNJABI": "Punjabi", "BENGALI": "Bengali", "KANNADA": "Kannada", "MALAYALAM": "Malayalam",
            "BHOJPURI": "Bhojpuri", "ODIA": "Odia", "ASSAMESE": "Assamese",
            "URDU": "Urdu", "AFR": "African", "EXYU": "Ex-Yugoslav"
        ]
        for region in ["IN", "HINDI", "INDIA", "DESI"] { map[region] = "Hindi" }
        for region in ["NP", "NEPAL", "NEPALI"] { map[region] = "Nepali" }
        return map
    }()

    private static let regionPrefix = try! NSRegularExpression(pattern: "^\\s*([A-Za-z]{2,12})\\s*[:|]")
    private static let arabicScript = try! NSRegularExpression(pattern: "[\\u0600-\\u06FF]")

    /// The region code from the channel's PREFIX only (before the first : or |).
    /// A prefix-only match avoids false hits like "Men IN Black" landing in Hindi.
    static func regionOf(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regionPrefix.firstMatch(in: name, range: range),
              let r = Range(match.range(at: 1), in: name) else { return nil }
        let code = name[r].uppercased()
        return regionToBucket[code] != nil ? code : nil
    }

    /// The language bucket label for one channel name; "Other" when it has no known prefix.
    static func bucketOf(_ name: String) -> String {
        guard let region = regionOf(name), let bucket = regionToBucket[region] else { return "Other" }
        // The provider mislabels some Arabic-script channels under NP:.
        if bucket == "Nepali", arabicScript.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return "Arabic"
        }
        return bucket
    }

    // MARK: Adult filtering

    private let lock = NSLock()
    private var adultFilterOnStorage = true
    private var adultCategoryIds: Set<String> = []
    private var cachedGroups: [Group]?
    private var cachedGroupsCount = -1

    /// Set from the app's setting; the grouping is rebuilt when it changes.
    var adultFilterOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return adultFilterOnStorage }
        set {
            lock.lock(); defer { lock.unlock() }
            if adultFilterOnStorage != newValue { adultFilterOnStorage = newValue; cachedGroups = nil }
        }
    }

    /// Remember which provider categories are adult so every channel filed under one
    /// is hidden even when its own name looks innocent. Pass the unfiltered list.
    func markAdultCategories(from categories: [ChannelCategory]) {
        let ids = Set(categories.filter { AdultFilter.isAdultCategory($0.name) }.map { $0.id })
        lock.lock(); defer { lock.unlock() }
        if ids != adultCategoryIds { adultCategoryIds = ids; cachedGroups = nil }
    }

    /// True when the channel must stay out of every browse surface right now.
    func isHidden(_ entry: Entry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hiddenLocked(entry)
    }

    private func hiddenLocked(_ entry: Entry) -> Bool {
        adultFilterOnStorage && (entry.adult || adultCategoryIds.contains(entry.categoryId))
    }

    /// Drop the memoized grouping (the catalog was replaced, e.g. after a refresh).
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedGroups = nil
    }

    // MARK: Lists

    /// Ordered language groups: biggest languages first, "Other" always last.
    /// Memoized until the filter, the adult categories, or the catalog size changes.
    func groups(from live: [Entry]) -> [Group] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedGroups, cachedGroupsCount == live.count { return cached }
        if live.isEmpty { return [] }
        var byBucket: [String: [Entry]] = [:]
        var order: [String] = []
        for channel in live where !hiddenLocked(channel) {
            let bucket = Self.bucketOf(channel.name)
            if byBucket[bucket] == nil { order.append(bucket) }
            byBucket[bucket, default: []].append(channel)
        }
        var groups = order.filter { $0 != "Other" }
            .map { Group(label: $0, channels: byBucket[$0] ?? []) }
            .sorted { $0.count > $1.count }
        if let other = byBucket["Other"] { groups.append(Group(label: "Other", channels: other)) }
        cachedGroups = groups
        cachedGroupsCount = live.count
        return groups
    }

    /// Bucket labels with their channel counts, biggest first, "Other" last.
    func groupCounts(from live: [Entry]) -> [(label: String, count: Int)] {
        groups(from: live).map { ($0.label, $0.count) }
    }

    /// Channels of one language bucket, in catalog order.
    func channels(inGroup label: String, from live: [Entry]) -> [Entry] {
        groups(from: live).first { $0.label == label }?.channels ?? []
    }

    /// Channels (across all languages) matching a smart list, in catalog order.
    func channels(matching smart: SmartList, from live: [Entry]) -> [Entry] {
        live.filter { smart.matches(upperName: $0.name.uppercased()) && !isHidden($0) }
    }

    /// Channels of one provider category with adult channels removed.
    func channels(inCategory categoryId: String, from live: [Entry]) -> [Entry] {
        live.filter { $0.categoryId == categoryId && !isHidden($0) }
    }

    /// Visible channels for a set of favorite ids, in catalog order.
    func channels(withIds ids: Set<Int>, from live: [Entry]) -> [Entry] {
        live.filter { ids.contains($0.id) && !isHidden($0) }
    }
}
