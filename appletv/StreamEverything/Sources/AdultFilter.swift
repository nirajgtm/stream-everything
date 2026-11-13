import Foundation

/// Hides adult titles. Same rules as the Android app, so both apps hide the same items.
enum AdultFilter {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Titles that open with an adult marker, e.g. "XXX - ..." or "### ADULT ###".
    private static let context = regex("^\\s*[#*\\s]*(XXX|ADULT)(?!\\s*SWIM)\\b")

    private static let hard = regex(
        "(^|[^a-z])(" +
        "xxx|pr0n|hentai|creampie|blowjob|cumshot|handjob|gangbang|bukkake|" +
        "deepthroat|fisting|footjob|titjob|rimjob|squirting|" +
        "brazzers|dorcel|evilangel|bangbros|naughty\\s*america|realitykings|mofos|" +
        "twistys|sextreme|dogfart|pornhub|xhamster|redtube|youporn|" +
        "hustler\\s*tv|playboy\\s*tv|penthouse\\s*tv|vivid\\s*tv|private\\s*tv|redlight|" +
        "camgirl|chaturbate|camsoda|" +
        "hardcore\\s*(sex|porn)|softcore|porno|" +
        "anal\\s|anal$|bdsm|bondage\\s*porn|fetish\\s*(porn|model)" +
        ")([^a-z]|$)")

    private static let soft = regex(
        "(^|[^a-z])(" +
        "sex|sexy|sexo|sesso|seks|sexe|porn|adult|erotic|erotik|erotique|" +
        "nude|nudist|naked|topless|stripper|striptease|strip\\s*club|" +
        "fetish|kink|taboo|voyeur|swinger|orgy|orgasm|escort|hooker|" +
        "boobs|tits|pussy|horny|onlyfans|18\\+|21\\+|hardcore|playboy|penthouse|hustler" +
        ")([^a-z]|$)")

    /// Titles the rules misjudge: the xXx action films, documentaries about the
    /// industry, and racy but ordinary reality TV.
    private static let allow = [
        "xander cage", "triple x", "xxx 2:", "xxx2", "xxx²", "xxx: state of the union",
        "xxx - il ritorno", "xxx: o regresso", "estado de emergencia", "xxx (2002)",
        "xxx: the next level", "xxx 2: the next level",
        "my dad wrote a porno", "money shot: the pornhub story", "my dead dad's porno tapes",
        "porno y helado", "hardcore: no submundo", "after porn ends", "hippy porn",
        "the hentai prince", "x-rated queen", "porn king", "thinking xxx",
        "historia de pornhub", "make a porno", "bdsm en vaerld",
        "milf manor", "milf of norway", "extreme cougar wives", "cougar town",
        "milf - ferien", "milf (2018)", "aspirational slut", "fifty shades of fetish model",
        "the escort", "escort boys", "secret escort", "escort in love", "cougar hunting",
        "adult swim", "adult-swim", "adult alternative", "adult animation",
        "adult material", "young adult", "adult best friends", "adult life skills"
    ]

    /// "NF - xXx": the action franchise always sits behind a language tag.
    private static let franchise = regex("^[A-Za-z0-9+\\-]{1,6}\\s*-\\s*xxx\\b")

    /// Every rule needs one of these somewhere in the title, so a plain scan rejects
    /// almost the whole catalog without running a regex.
    private static let markers = [
        "xxx", "adult", "porn", "sex", "seks", "sesso", "sexe", "sexo", "erot",
        "nude", "nudist", "naked", "topless", "strip", "hardcore", "softcore",
        "milf", "cougar", "slut", "whore", "anal", "bdsm", "bondage", "fetish",
        "kink", "taboo", "voyeur", "swinger", "orgy", "orgasm", "escort", "hooker",
        "boobs", "tits", "pussy", "horny", "onlyfans", "18+", "21+", "hentai",
        "creampie", "blowjob", "cumshot", "handjob", "gangbang", "bukkake",
        "deepthroat", "fisting", "footjob", "titjob", "rimjob", "squirt",
        "brazzers", "dorcel", "evilangel", "bangbros", "naughty", "realitykings",
        "mofos", "twistys", "sextreme", "dogfart", "xhamster", "redtube", "youporn",
        "hustler", "playboy", "penthouse", "vivid", "private", "redlight",
        "camgirl", "chaturbate", "camsoda", "pr0n", "x-rated", "xrated"
    ]

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isAdult(_ name: String) -> Bool {
        if name.isEmpty { return false }
        let lower = name.lowercased()
        if !markers.contains(where: { lower.contains($0) }) { return false }
        if matches(franchise, name.trimmingCharacters(in: .whitespaces)) { return false }
        if allow.contains(where: { lower.contains($0) }) { return false }
        if matches(context, name) || matches(hard, name) { return true }
        // A soft word alone is meaningless; two distinct ones is the signal.
        var seen = Set<String>()
        let range = NSRange(name.startIndex..., in: name)
        for match in soft.matches(in: name, range: range) {
            if let r = Range(match.range(at: 2), in: name) {
                seen.insert(name[r].lowercased())
                if seen.count >= 2 { return true }
            }
        }
        return false
    }

    static func isAdultCategory(_ categoryName: String) -> Bool {
        let lower = categoryName.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("adult swim") || lower.contains("adult-swim") { return false }
        return lower == "for adults" || lower.hasPrefix("xxx") || lower.hasPrefix("adult") || lower.contains("porn")
    }
}
