import Foundation

/// A pill to render after a title: readable text plus a background color (hex).
struct Pill: Hashable {
    let text: String
    let color: String
}

/// A raw provider title split into a clean display name, its year, and readable pills.
struct ParsedTitle: Hashable {
    let clean: String
    let year: String?
    let pills: [Pill]
}

/// A season/episode pair read from a title tag like "S01E04" or "1x04".
struct SeasonEpisode: Hashable {
    let season: Int
    let episode: Int
}

/// Human-readable dictionaries for the acronyms and tags that appear in title
/// prefixes, taken from a frequency analysis of the whole catalog. Editable by
/// hand: add a code here and it becomes a readable pill everywhere. Unknown codes
/// pass through untouched so new content never disappears.
enum TitleRules {
    /// Region/language codes seen as title prefixes -> readable label.
    static let languages: [String: String] = [
        "EN": "English", "AR": "Arabic", "DE": "German", "FR": "French",
        "IN": "Hindi", "GR": "Greek", "IR": "Persian", "ES": "Spanish",
        "AL": "Albanian", "PT": "Portuguese", "NL": "Dutch", "SE": "Swedish",
        "TR": "Turkish", "IT": "Italian", "PL": "Polish", "RU": "Russian",
        "RO": "Romanian", "BG": "Bulgarian", "IL": "Hebrew", "PH": "Filipino",
        "TL": "Tagalog", "KU": "Kurdish", "SO": "Somali", "MM": "Burmese",
        "EG": "Egyptian", "DK": "Danish", "KH": "Khmer", "NO": "Norwegian",
        "BE": "Belgian", "QC": "Québécois", "MA": "Moroccan", "FI": "Finnish",
        "CZ": "Czech", "HU": "Hungarian", "HR": "Croatian", "RS": "Serbian",
        "UA": "Ukrainian", "VN": "Vietnamese", "TH": "Thai", "ID": "Indonesian",
        "MY": "Malay", "KR": "Korean", "JP": "Japanese", "CN": "Chinese",
        "TW": "Taiwanese", "HK": "Cantonese", "US": "American", "GB": "British",
        "CA": "Canadian", "AU": "Australian", "MX": "Mexican", "BR": "Brazilian",
        "PK": "Pakistani", "BD": "Bengali", "LK": "Sri Lankan", "NP": "Nepali"
    ]

    /// Streaming source / network codes -> readable label + brand color.
    static let sources: [String: (label: String, color: String)] = [
        "NF": ("Netflix", "#E50914"),
        "AMZ": ("Prime Video", "#00A8E1"),
        "AMZN": ("Prime Video", "#00A8E1"),
        "D+": ("Disney+", "#113CCF"),
        "DSNY": ("Disney+", "#113CCF"),
        "A+": ("Apple TV+", "#7D7D7D"),
        "ATV": ("Apple TV+", "#7D7D7D"),
        "HBO": ("HBO Max", "#8E44AD"),
        "MAX": ("HBO Max", "#8E44AD"),
        "HULU": ("Hulu", "#1CE783"),
        "PMT": ("Paramount+", "#0064FF"),
        "P+": ("Paramount+", "#0064FF"),
        "PCK": ("Peacock", "#FA6400"),
        "TOP": ("New Release", "#F5A623"),
        "4KTOP": ("New Release", "#F5A623")
    ]

    /// Content/audio hints -> readable label.
    static let hints: [String: String] = [
        "SUBS": "Subtitles", "SUB": "Subtitles", "DUB": "Dubbed",
        "MULTI": "Multi-audio", "ANM": "Anime", "DOC": "Documentary",
        "KIDS": "Kids", "XXX": "Adult", "VIP": "VIP", "SOC": "Soccer",
        "SPORT": "Sport", "SC": "Nordic",
        "CAM": "Cam", "HDCAM": "Cam", "CAMRIP": "Cam", "TS": "Cam", "HDTS": "Cam", "TELESYNC": "Cam",
        "TC": "Cam", "HDTC": "Cam", "HALL": "Cam", "PRE": "Cam", "WORKPRINT": "Cam", "DVDSCR": "Screener", "SCR": "Screener"
    ]

    /// Quality/format codes (including unicode superscript variants) -> readable label.
    static let quality: [String: String] = [
        "4K": "4K", "UHD": "4K", "ᵁᴴᴰ": "4K", "FHD": "FHD", "HD": "HD",
        "SD": "SD", "RAW": "RAW", "ᴿᴬᵂ": "RAW", "HDR": "HDR", "HEVC": "HEVC",
        "DV": "Dolby Vision", "3D": "3D", "IMAX": "IMAX"
    ]

    /// The provider's own brand tag and pure decoration, dropped silently.
    static let dropTokens: Set<String> = ["SHAM", "EX", "S", "B", "D", "AS"]

    /// Pill palette for categories without a brand color.
    static let colorLanguage = "#4A6FA5"
    static let colorQuality = "#B8860B"
    static let colorHint = "#2E8B78"
    static let colorYear = "#556677"
}

/// Turns a raw provider title like "4K-NF - Mousetrap (2026) (KR)" into a clean
/// name ("Mousetrap") plus readable pills (Netflix, 4K, 2026, Korean). Unknown
/// prefix tokens are kept in the title so nothing silently disappears.
enum TitleParser {
    /// Search keys of the title starting at each word: "The Office (US)" ->
    /// ["theofficeus", "officeus", "us"]. Cheap enough for the few hundred candidates
    /// a search ranks, not meant for the whole catalog.
    static func wordStarts(_ name: String) -> [String] {
        let words = TitleText.display(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0).lowercased() }
        var out: [String] = []
        for i in words.indices { out.append(words[i...].joined()) }
        return out
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let yearPattern = regex("\\((19|20)\\d{2}\\)")
    private static let trailingCountry = regex("\\(([A-Z]{2})\\)\\s*$")
    private static let leadingQualityColon = regex("^\\s*(4K|UHD|FHD|HD|SD|RAW)\\s*:\\s*", [.caseInsensitive])
    private static let superscriptJunk = regex("[³⁸⁴⁰ᴾᴺᴹ]+")
    private static let decorations = regex("#{2,}|▶|★|●|•")
    private static let prefixSeparator = regex("\\s*[-|]\\s*")
    private static let repeatedSpaces = regex("\\s{2,}")
    private static let seasonEpisodeTag = regex("\\b(s\\d{1,2}\\s*[.x-]?\\s*e\\d{1,3}|\\d{1,2}x\\d{1,3})\\b", [.caseInsensitive])
    private static let seasonEpisodeNumbers = regex("\\bs(\\d{1,2})\\s*[.x-]?\\s*e(\\d{1,3})\\b|\\b(\\d{1,2})x(\\d{1,3})\\b", [.caseInsensitive])
    private static let seriesTitleWithTag = regex("^(.*?)\\s+S(\\d+)\\s*E(\\d+)", [.caseInsensitive])

    /// Characters that are meaningless at either end of a title once tags are gone.
    private static let edgeJunk = CharacterSet(charactersIn: " -:|.·–")

    static func parse(_ raw: String) -> ParsedTitle {
        var work = raw
        var pills: [Pill] = []   // deduped by text, insertion order kept
        func addPill(_ text: String, _ color: String) {
            if !pills.contains(where: { $0.text == text }) { pills.append(Pill(text: text, color: color)) }
        }

        // Superscript quality marks (live): ᵁᴴᴰ, ᴿᴬᵂ -> pills, then strip below.
        for (mark, label) in [("ᵁᴴᴰ", "4K"), ("ᴿᴬᵂ", "RAW")] where work.contains(mark) {
            addPill(label, TitleRules.colorQuality)
            work = work.replacingOccurrences(of: mark, with: " ")
        }

        // Leading "4K:" style quality prefix (live channels).
        if let match = leadingQualityColon.firstMatch(in: work, range: wholeRange(work)),
           let whole = Range(match.range, in: work), let code = Range(match.range(at: 1), in: work) {
            if let label = TitleRules.quality[work[code].uppercased()] { addPill(label, TitleRules.colorQuality) }
            work.removeSubrange(whole)
            work = work.trimmingCharacters(in: .whitespaces)
        }

        // Trailing country code, e.g. "... (KR)".
        if let match = trailingCountry.firstMatch(in: work, range: wholeRange(work)),
           let whole = Range(match.range, in: work), let code = Range(match.range(at: 1), in: work) {
            if let label = TitleRules.languages[String(work[code])] { addPill(label, TitleRules.colorLanguage) }
            work.removeSubrange(whole)
            work = work.trimmingCharacters(in: .whitespaces)
        }

        // Year, e.g. "(2026)".
        var year: String?
        if let match = yearPattern.firstMatch(in: work, range: wholeRange(work)), let r = Range(match.range, in: work) {
            let value = work[r].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            year = value
            addPill(value, TitleRules.colorYear)
        }

        // Prefix tag segments before the main title, split on " - " / "|".
        let parts = split(work, on: prefixSeparator)
        if parts.count > 1 {
            var consumed = 0
            for part in parts.dropLast() {
                if !classifyPrefix(part.trimmingCharacters(in: .whitespaces), addPill: addPill) { break }
                consumed += 1
            }
            if consumed > 0 { work = parts.dropFirst(consumed).joined(separator: " - ") }
        }

        // Final cleanup: drop the year from the title, then decoration and whitespace.
        work = replaceFirst(yearPattern, in: work, with: "")
        work = decorations.stringByReplacingMatches(in: work, range: wholeRange(work), withTemplate: " ")
        work = superscriptJunk.stringByReplacingMatches(in: work, range: wholeRange(work), withTemplate: " ")
        work = repeatedSpaces.stringByReplacingMatches(in: work, range: wholeRange(work), withTemplate: " ")
        work = work.trimmingCharacters(in: edgeJunk)

        return ParsedTitle(clean: work.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : work, year: year, pills: pills)
    }

    /// Just the clean name, for callers that do not render pills.
    static func clean(_ raw: String) -> String { parse(raw).clean }

    /// Read one prefix chunk as tags; true when the whole chunk was tags.
    private static func classifyPrefix(_ chunk: String, addPill: (String, String) -> Void) -> Bool {
        if chunk.isEmpty || chunk.count > 8 { return false }
        let token = chunk.uppercased()
        if let label = TitleRules.quality[token] { addPill(label, TitleRules.colorQuality); return true }
        if let source = TitleRules.sources[token] { addPill(source.label, source.color); return true }
        if let label = TitleRules.languages[token] { addPill(label, TitleRules.colorLanguage); return true }
        if let label = TitleRules.hints[token] { addPill(label, TitleRules.colorHint); return true }
        return TitleRules.dropTokens.contains(token)
    }

    // MARK: Language prefix

    /// Language/region code from a title prefix like "EN - " or "DE|", nil if none.
    /// Hand-rolled instead of a regex because it runs over every catalog entry.
    static func languageCode(of name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        var i = 0
        while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
        let start = i
        while i < scalars.count, isAsciiLetter(scalars[i]) { i += 1 }
        let letters = i - start
        guard letters >= 2, letters <= 3 else { return nil }
        while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
        guard i < scalars.count, scalars[i] == "-" || scalars[i] == "|" || scalars[i] == ":" else { return nil }
        return String(String.UnicodeScalarView(scalars[start..<(start + letters)])).uppercased()
    }

    private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
    }

    /// Title without its language prefix: "EN - Batman (2026)" -> "Batman (2026)".
    static func displayTitle(_ name: String) -> String { TitleText.display(name) }

    // MARK: Episodes

    /// Episode title without redundant "S01E01"-style tags (already parsed into fields).
    static func cleanEpisodeTitle(_ title: String) -> String {
        var work = seasonEpisodeTag.stringByReplacingMatches(in: title, range: wholeRange(title), withTemplate: " ")
        work = repeatedSpaces.stringByReplacingMatches(in: work, range: wholeRange(work), withTemplate: " ")
        return work.trimmingCharacters(in: edgeJunk)
    }

    /// The season/episode numbers inside a title ("S02E05", "s2.e5", "2x05"), nil when absent.
    static func seasonEpisode(in title: String) -> SeasonEpisode? {
        guard let match = seasonEpisodeNumbers.firstMatch(in: title, range: wholeRange(title)) else { return nil }
        func group(_ index: Int) -> Int? {
            guard let r = Range(match.range(at: index), in: title) else { return nil }
            return Int(title[r])
        }
        if let season = group(1), let episode = group(2) { return SeasonEpisode(season: season, episode: episode) }
        if let season = group(3), let episode = group(4) { return SeasonEpisode(season: season, episode: episode) }
        return nil
    }

    /// Splits a Continue Watching label like "Breaking Bad S03E07" into the series
    /// name and its position, so the series can be found again by title.
    static func splitSeriesTitle(_ label: String) -> (series: String, position: SeasonEpisode)? {
        guard let match = seriesTitleWithTag.firstMatch(in: label, range: wholeRange(label)),
              let nameRange = Range(match.range(at: 1), in: label),
              let seasonRange = Range(match.range(at: 2), in: label),
              let episodeRange = Range(match.range(at: 3), in: label),
              let season = Int(label[seasonRange]), let episode = Int(label[episodeRange]) else { return nil }
        return (label[nameRange].trimmingCharacters(in: .whitespaces), SeasonEpisode(season: season, episode: episode))
    }

    /// Trailing "(KR)" country code in uppercase, or "" when the title has none.
    static func trailingCountryCode(of name: String) -> String {
        guard let match = trailingCountry.firstMatch(in: name, range: wholeRange(name)),
              let r = Range(match.range(at: 1), in: name) else { return "" }
        return name[r].uppercased()
    }

    // MARK: Search text

    /// Lowercase letters and digits only, accents removed: "The Back-Rooms" -> "thebackrooms".
    static func normalizeForSearch(_ text: String) -> String { TitleText.searchKey(text) }

    // MARK: Small regex helpers

    private static func wholeRange(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    private static func replaceFirst(_ re: NSRegularExpression, in text: String, with replacement: String) -> String {
        guard let match = re.firstMatch(in: text, range: wholeRange(text)), let r = Range(match.range, in: text) else { return text }
        var out = text
        out.replaceSubrange(r, with: replacement)
        return out
    }

    private static func split(_ text: String, on re: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var cursor = text.startIndex
        for match in re.matches(in: text, range: wholeRange(text)) {
            guard let r = Range(match.range, in: text) else { continue }
            parts.append(String(text[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        parts.append(String(text[cursor...]))
        return parts
    }
}

/// Query words minus stopwords ("The backroom" matches like "backroom"), while the
/// stopword-included form still ranks exact titles first. A query made only of
/// stopwords keeps them as real tokens.
struct ParsedQuery {
    private static let stopwords: Set<String> = ["the", "a", "an"]

    let tokens: [String]
    /// All words joined, stopwords included: "thebackroom".
    let whole: String
    /// Meaningful words joined: "backroom".
    let core: String
    let valid: Bool

    init(_ query: String) {
        let allTokens = query.split(whereSeparator: { $0.isWhitespace })
            .map { TitleParser.normalizeForSearch(String($0)) }.filter { !$0.isEmpty }
        let meaningful = allTokens.filter { !Self.stopwords.contains($0) }
        tokens = meaningful.isEmpty ? allTokens : meaningful
        whole = allTokens.joined()
        core = tokens.joined()
        valid = core.count >= 2
    }

    func matches(_ entry: Entry) -> Bool { tokens.allSatisfy { entry.searchKey.contains($0) } }

    /// 0 = contains the query verbatim, 1 = contains the meaningful words joined, 2 = scattered words.
    func rank(_ entry: Entry) -> Int {
        // Keys have no spaces, so "ofice" sits inside "knifeofice". A hit at a word
        // start of the real title ("The Office") outranks one buried mid-word.
        let atWordStart = TitleParser.wordStarts(entry.name).contains { $0.hasPrefix(core) || $0.hasPrefix(whole) }
        if entry.searchKey.contains(whole) { return atWordStart ? 0 : 2 }
        if entry.searchKey.contains(core) { return atWordStart ? 1 : 3 }
        return 4
    }
}
