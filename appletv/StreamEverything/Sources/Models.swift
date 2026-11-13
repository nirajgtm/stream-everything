import Foundation

enum Kind: String, Codable, CaseIterable { case live, movie, series }

/// One catalog item: a live channel, a movie, or a series.
struct Entry: Identifiable, Hashable {
    let kind: Kind
    let name: String
    let id: Int
    let ext: String
    let logo: String
    let categoryId: String

    /// Lowercase letters and digits only, for search.
    let searchKey: String
    let adult: Bool
    /// Language/region code from a title prefix like "EN - " or "DE|", nil if none.
    /// Stored, not computed, because search filters read it for every row.
    let lang: String?
    /// Live-channel metadata (empty/0 for movies and series), as the Android Entry carries.
    let epgId: String
    let archive: Int

    init(kind: Kind, name: String, id: Int, ext: String, logo: String, categoryId: String,
         epgId: String = "", archive: Int = 0) {
        self.kind = kind
        self.name = name
        self.id = id
        self.ext = ext
        self.logo = logo
        self.categoryId = categoryId
        self.epgId = epgId
        self.archive = archive
        self.searchKey = TitleText.searchKey(name)
        self.adult = AdultFilter.isAdult(name)
        self.lang = TitleParser.languageCode(of: name)
    }

    /// Rebuild from the binary catalog cache: every derived field was stored, so a cold
    /// start does no text folding or adult-rule matching for 300k entries.
    init(kind: Kind, name: String, id: Int, ext: String, logo: String, categoryId: String,
         epgId: String, archive: Int, searchKey: String, adult: Bool, lang: String?) {
        self.kind = kind; self.name = name; self.id = id; self.ext = ext; self.logo = logo
        self.categoryId = categoryId; self.epgId = epgId; self.archive = archive
        self.searchKey = searchKey; self.adult = adult; self.lang = lang
    }

    /// Title without a leading language tag like "EN - " or "NF - ".
    var displayTitle: String { TitleText.display(name) }
}

struct Episode: Identifiable, Hashable {
    let id: Int
    let season: Int
    let number: Int
    let title: String
    let ext: String
    let plot: String
    let still: String
    let durationSeconds: Int
}

struct SeriesInfo {
    let plot: String
    let cover: String
    let backdrop: String
    let year: String
    let genre: String
    let cast: String
    let episodes: [Episode]
    /// Extras the detail pages read; defaulted so the plain `seriesInfo` loader still compiles.
    var rating: String = ""
    var tmdbId: Int = 0
    var seasons: [Int] { Array(Set(episodes.map { $0.season })).sorted() }
}

struct MovieInfo {
    let plot: String
    let backdrop: String
    let year: String
    let genre: String
    let cast: String
    let durationSeconds: Int
    /// Extras the detail page reads; defaulted so the plain `movieInfo` loader still compiles.
    var poster: String = ""
    var rating: String = ""
    var tmdbId: Int = 0
    var trailer: String = ""
}

struct ChannelCategory: Identifiable {
    let id: String
    let name: String
}

enum TitleText {
    private static let languageTag = try! NSRegularExpression(pattern: "^\\s*[A-Za-z]{2,3}\\s*[-|:]\\s*")

    static func display(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        if let match = languageTag.firstMatch(in: name, range: range), let r = Range(match.range, in: name) {
            let rest = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return name
    }

    static func searchKey(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}
