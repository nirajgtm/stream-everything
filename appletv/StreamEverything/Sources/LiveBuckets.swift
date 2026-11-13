import Foundation

/// Groups live channels into language buckets from their region-code prefix
/// ("US|", "NP:", "HINDI |") and offers cross-cutting "smart lists" (news, soccer,
/// kids...) that cut across languages. Port of the Android LiveCatalog; kept
/// self-contained so the Live TV screens do not depend on the catalog loader.
enum LiveBuckets {

    // MARK: Channel type (the chips above the channel list)

    /// Coarse channel type detected from keywords in the name. Only the six named
    /// types are offered as filter chips; everything else is `.general`.
    enum ChannelType: String, CaseIterable, Identifiable {
        case sports = "Sports", news = "News", movies = "Movies", kids = "Kids", music = "Music", docs = "Docs", general = "General"
        var id: String { rawValue }

        var keywords: [String] {
            switch self {
            case .sports: return ["SPORT", "SOCCER", "FOOTBALL", "NBA", "NFL", "UFC", "F1", "CRICKET", "GOLF", "TENNIS", "RUGBY", "BOXING", "HOCKEY", "BASEBALL"]
            case .news: return ["NEWS", "CNN", "BBC", "FOX", "ALJAZEERA"]
            case .movies: return ["CINEMA", "MOVIE", "FILM"]
            case .kids: return ["KIDS", "CARTOON", "DISNEY", "NICK", "BABY"]
            case .music: return ["MUSIC", "MTV", "RADIO", "HITS"]
            case .docs: return ["DOCU", " DOC", "HISTORY", "NATURE", "DISCOVERY", "NAT GEO", "GEO"]
            case .general: return []
            }
        }

        /// The chips shown in the browse screen, in display order.
        static let chips: [ChannelType] = [.sports, .news, .movies, .kids, .music, .docs]

        static func of(_ name: String) -> ChannelType {
            let upper = name.uppercased()
            for type in chips where type.keywords.contains(where: { upper.contains($0) }) { return type }
            return .general
        }
    }

    // MARK: Language buckets

    /// Region code -> bucket label. Several regions share one bucket (US/UK/CA each
    /// get their own English bucket because plain "English" was too big to browse).
    private static let regionToBucket: [String: String] = {
        var map: [String: String] = [:]
        map["US"] = "English US"; map["USA"] = "English US"
        map["UK"] = "English UK"; map["GB"] = "English UK"; map["IE"] = "English UK"
        map["CA"] = "English CA"
        map["AU"] = "English AU/NZ"; map["NZ"] = "English AU/NZ"
        map["EN"] = "English"
        for r in ["IN", "HINDI", "INDIA", "DESI"] { map[r] = "Hindi" }
        for r in ["NP", "NEPAL", "NEPALI"] { map[r] = "Nepali" }
        let simple: [(String, String)] = [
            ("AR", "Arabic"), ("FR", "French"), ("DE", "German"), ("IT", "Italian"),
            ("TR", "Turkish"), ("NL", "Dutch"), ("ES", "Spanish"), ("GR", "Greek"),
            ("AL", "Albanian"), ("BE", "Belgian"), ("SE", "Swedish"), ("IR", "Persian"),
            ("IL", "Hebrew"), ("RU", "Russian"), ("HR", "Croatian"), ("BG", "Bulgarian"),
            ("DK", "Danish"), ("PH", "Filipino"), ("NO", "Norwegian"), ("BR", "Brazilian"),
            ("RS", "Serbian"), ("FI", "Finnish"), ("PT", "Portuguese"), ("CZ", "Czech"),
            ("MX", "Mexican"), ("PL", "Polish"), ("RO", "Romanian"), ("HU", "Hungarian"),
            ("UA", "Ukrainian"), ("VN", "Vietnamese"), ("TH", "Thai"), ("ID", "Indonesian"),
            ("MY", "Malay"), ("KR", "Korean"), ("JP", "Japanese"), ("CN", "Chinese"),
            ("PK", "Pakistani"), ("BD", "Bengali"), ("LK", "Sri Lankan"), ("EG", "Egyptian"),
            ("MA", "Moroccan"), ("AT", "Austrian"), ("CH", "Swiss"),
            // Indian languages that carry their own prefix.
            ("TAMIL", "Tamil"), ("TELUGU", "Telugu"), ("MARATHI", "Marathi"), ("GUJARATI", "Gujarati"),
            ("PUNJABI", "Punjabi"), ("BENGALI", "Bengali"), ("KANNADA", "Kannada"), ("MALAYALAM", "Malayalam"),
            ("BHOJPURI", "Bhojpuri"), ("ODIA", "Odia"), ("ASSAMESE", "Assamese"), ("URDU", "Urdu"),
            ("AFR", "African"), ("EXYU", "Ex-Yugoslav")
        ]
        for (code, label) in simple { map[code] = label }
        return map
    }()

    private static let regionPrefix = try! NSRegularExpression(pattern: "^\\s*([A-Za-z]{2,12})\\s*[:|]")
    private static let arabicScript = try! NSRegularExpression(pattern: "[\\u0600-\\u06FF]")

    /// The region code from the channel's prefix only (before the first ":" or "|").
    /// Matching the prefix alone avoids "Men IN Black" landing in Hindi.
    static func region(of name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regionPrefix.firstMatch(in: name, range: range),
              let r = Range(match.range(at: 1), in: name) else { return nil }
        let code = name[r].uppercased()
        return regionToBucket[code] != nil ? code : nil
    }

    /// Language bucket label for a channel name; "Other" when the prefix is unknown.
    static func bucket(of name: String) -> String {
        guard let region = region(of: name), let bucket = regionToBucket[region] else { return "Other" }
        // The provider files some Arabic-script channels under NP:; keep them out of Nepali.
        if bucket == "Nepali",
           arabicScript.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            return "Arabic"
        }
        return bucket
    }

    struct Group: Identifiable {
        let label: String
        let channels: [Entry]
        var id: String { label }
    }

    // MARK: Smart lists

    /// A tag-based list that cuts across languages; a channel can sit in several.
    struct SmartList: Identifiable {
        let label: String
        let keys: [String]
        var id: String { label }

        func matches(upperName: String) -> Bool { keys.contains { upperName.contains($0) } }

        /// Label without the leading emoji, for alphabetical sorting.
        var sortKey: String {
            String(label.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        }
    }

    static let smartLists: [SmartList] = [
        SmartList(label: "Live Events", keys: ["EVENT"]),
        SmartList(label: "PPV", keys: ["PPV"]),
        SmartList(label: "24/7 Movies & Series", keys: ["24/7", "24-7"]),
        SmartList(label: "📰 News", keys: ["NEWS", "CNN", "ALJAZEERA", "AL JAZEERA", "MSNBC", "EURONEWS", "SKY NEWS", "FOX NEWS", "GB NEWS", "CNBC", "BLOOMBERG"]),
        SmartList(label: "🎬 Movies", keys: ["CINEMA", "MOVIE", " FILM", "CINE ", "PELICULA"]),
        SmartList(label: "🎞 Documentary", keys: ["DOCU", " DOC ", "HISTORY", "DISCOVERY", "NAT GEO", "NATGEO", "NATURE", "ANIMAL PLANET"]),
        SmartList(label: "🧸 Kids", keys: ["KIDS", "DISNEY", "NICK", "BABY", "JUNIOR"]),
        SmartList(label: "🍥 Anime", keys: ["ANIME", "CRUNCHYROLL", "TOONAMI", "MANGA"]),
        SmartList(label: "✏ Animation", keys: ["ANIMATION", "CARTOON", "ANIMATED", "TOONS"]),
        SmartList(label: "🎵 Music", keys: ["MUSIC", "MTV", "VEVO", " HITS", "RADIO"]),
        SmartList(label: "⚽ Soccer", keys: ["SOCCER", "FOOTBALL", "FUTBOL", "CALCIO", " LIGA", "LALIGA", "PREMIER LEAGUE", "UEFA", "CHAMPIONS LEAGUE", "EUROPA", "SERIE A", "BUNDESLIGA", "LIGUE 1", "EREDIVISIE", "MLS", "EPL", "FA CUP", "CONMEBOL"]),
        SmartList(label: "🏀 Basketball", keys: ["BASKETBALL", "NBA", "EUROLEAGUE"]),
        SmartList(label: "🏈 American Football", keys: ["NFL", "AMERICAN FOOTBALL", "SUPER BOWL"]),
        SmartList(label: "🥊 Boxing & MMA", keys: ["BOXING", "UFC", " MMA", "BELLATOR", "WBC", " FIGHT"]),
        SmartList(label: "🤼 Wrestling", keys: ["WWE", "WRESTL", "AEW", " NXT"]),
        SmartList(label: "🏏 Cricket", keys: ["CRICKET", " IPL", " BBL", " PSL", " T20"]),
        SmartList(label: "🎾 Tennis", keys: ["TENNIS", " ATP", " WTA", "WIMBLEDON", "ROLAND"]),
        SmartList(label: "⛳ Golf", keys: ["GOLF", " PGA", "RYDER"]),
        SmartList(label: "🏎 Motorsport", keys: ["FORMULA", "MOTOGP", "NASCAR", "RACING", "MOTORSPORT", " F1"]),
        SmartList(label: "🏒 Hockey", keys: ["HOCKEY", " NHL"]),
        SmartList(label: "⚾ Baseball", keys: ["BASEBALL", " MLB"])
    ]

    /// Channels across every language that match a smart list. Adult titles stay out
    /// of every browse surface, not only search.
    static func channels(in live: [Entry], matching smart: SmartList, adultFilter: Bool) -> [Entry] {
        live.filter { smart.matches(upperName: $0.name.uppercased()) && !(adultFilter && $0.adult) }
    }

    // MARK: Grouping (memoized)

    /// What the memoized grouping was computed from; a different catalog or filter
    /// setting invalidates it. Comparing count and a few ids is enough to notice a
    /// refreshed list without hashing 57k entries.
    private struct MemoKey: Equatable {
        let count: Int
        let firstId: Int
        let lastId: Int
        let adultFilter: Bool
    }
    private static var memo: (key: MemoKey, groups: [Group])?
    private static let memoLock = NSLock()

    /// Language groups, biggest first, "Other" always last. Grouping ~57k names with
    /// a regex is not free, so call this off the main actor and rely on the memo.
    static func group(_ live: [Entry], adultFilter: Bool) -> [Group] {
        if live.isEmpty { return [] }
        let key = MemoKey(count: live.count, firstId: live.first?.id ?? 0, lastId: live.last?.id ?? 0, adultFilter: adultFilter)
        memoLock.lock()
        if let memo, memo.key == key { memoLock.unlock(); return memo.groups }
        memoLock.unlock()

        var byBucket: [String: [Entry]] = [:]
        var order: [String] = []
        for channel in live {
            if adultFilter && channel.adult { continue }
            let label = bucket(of: channel.name)
            if byBucket[label] == nil { order.append(label) }
            byBucket[label, default: []].append(channel)
        }
        var groups = order.filter { $0 != "Other" }
            .map { Group(label: $0, channels: byBucket[$0] ?? []) }
            .sorted { $0.channels.count > $1.channels.count }
        if let other = byBucket["Other"] { groups.append(Group(label: "Other", channels: other)) }

        memoLock.lock()
        memo = (key, groups)
        memoLock.unlock()
        return groups
    }
}
