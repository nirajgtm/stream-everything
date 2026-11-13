import Foundation

/// Decides how "English" a catalog copy is, so English copies win everywhere a copy
/// is chosen or ordered: which duplicate a rail resolves to, which source a detail
/// page opens, how search results are ordered.
///
/// The provider tags copies with a leading label like "EN - ", "AR-ANM-S - ",
/// "4K-NF - " or "IN-KD - ". Any token of that label that names a non-English
/// language or country marks the copy as foreign, and so does non-Latin script
/// anywhere in the name (Arabic, Persian, Cyrillic, CJK, ...), which catches titles
/// with a translated name appended even when the label is unhelpful.
enum LanguagePreference {
    /// 0 = English or untagged original, 1 = unknown tag, 2 = another language.
    static func rank(name: String) -> Int {
        if hasNonLatinScript(name) { return 2 }
        let tokens = labelTokens(name)
        if tokens.contains(where: { englishCodes.contains($0) }) { return 0 }
        if tokens.contains(where: { foreignCodes.contains($0) }) { return 2 }
        return tokens.isEmpty ? 0 : (tokens.allSatisfy { neutralTokens.contains($0) } ? 0 : 1)
    }

    static func isEnglish(name: String) -> Bool { rank(name: name) == 0 }

    /// Tokens of the leading label before " - ", " | " or ":", uppercased and split on "-".
    static func labelTokens(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var end = trimmed.endIndex
        for separator in [" - ", " | ", "|", " : "] {
            if let r = trimmed.range(of: separator), r.lowerBound < end { end = r.lowerBound }
        }
        guard end < trimmed.endIndex else { return [] }
        let label = trimmed[..<end]
        // A real title ("Men in Black") is not a label: labels are short and have no spaces.
        guard label.count <= 12, !label.contains(" ") else { return [] }
        return label.uppercased().split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == "_" }).map(String.init)
    }

    static let englishCodes: Set<String> = ["EN", "ENG", "US", "USA", "UK", "GB", "AU", "CA", "NZ", "IE"]

    /// Quality and network tags that say nothing about language.
    static let neutralTokens: Set<String> = [
        "4K", "UHD", "FHD", "HD", "SD", "HDR", "DV", "NF", "AMZ", "PRIME", "HBO", "MAX", "DSNP",
        "DISNEY", "ATVP", "ATV", "APPLE", "HULU", "PCK", "PEACOCK", "PMT", "PARAMOUNT", "CR",
        "SHO", "STARZ", "AMC", "BBC", "ITV", "CW", "FX", "ABC", "NBC", "CBS", "FOX", "YT", "VIX", "TUBI"
    ]

    /// Language and country codes the provider uses for non-English copies.
    static let foreignCodes: Set<String> = [
        "AR", "ARB", "ARABIC", "IR", "FA", "PER", "IN", "HI", "HIN", "TA", "TE", "ML", "KN", "BN", "UR", "PK", "NP",
        "BD", "LK", "KD", "KU", "KUR", "TR", "TUR", "FR", "FRA", "DE", "GER", "ES", "SPA", "LAT", "MX", "IT", "ITA",
        "PT", "POR", "BR", "RU", "RUS", "UA", "PL", "NL", "SE", "SV", "NO", "DK", "DA", "FI", "GR", "GRE", "EL",
        "SC", "NORDIC", "RO", "BG", "HU", "CZ", "SK", "SI", "HR", "RS", "BA", "MK", "AL", "ALB", "EXYU", "IL", "HE", "HEB",
        "PH", "TL", "SO", "SOM", "MM", "TH", "VN", "VI", "ID", "MY", "KR", "KOR", "JP", "JPN", "CN", "CHI", "ZH",
        "TW", "HK", "EG", "MA", "DZ", "TN", "IQ", "SY", "LB", "JO", "KW", "QA", "AE", "SA", "YE", "AF", "ET", "ER", "NG", "KE", "ZA", "GH"
    ]

    static func hasNonLatinScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0590...0x08FF).contains(v)        // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan
                || (0x0400...0x052F).contains(v)    // Cyrillic
                || (0x0900...0x0DFF).contains(v)    // Devanagari through Sinhala
                || (0x0E00...0x0E7F).contains(v)    // Thai
                || (0x1100...0x11FF).contains(v)    // Hangul Jamo
                || (0x3040...0x30FF).contains(v)    // Hiragana, Katakana
                || (0x4E00...0x9FFF).contains(v)    // CJK
                || (0xAC00...0xD7AF).contains(v) {  // Hangul syllables
                return true
            }
        }
        return false
    }
}
