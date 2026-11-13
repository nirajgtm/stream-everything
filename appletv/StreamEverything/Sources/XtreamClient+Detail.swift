import Foundation

/// Richer title details for the movie and series pages: the plain `movieInfo` /
/// `seriesInfo` loaders drop the TMDB id and rating, but the detail pages need the
/// id to fetch cast headshots and episode stills without a title search. Field
/// fallbacks ("plot" or "overview", "cast" or "actors", "tmdb" or "tmdb_id") follow
/// the Android `XtreamClient.seriesDetail`, because providers disagree on the keys.
extension XtreamClient {
    private static let detailSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// Detail responses are kept on disk for a few hours: reopening a title then
    /// shows its seasons and plot at once instead of after a round trip, and a title
    /// opened again later still refreshes. Served from disk only when parseable.
    private func detailFetch(_ action: String, _ extra: String) async throws -> [String: Any] {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("details", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let name = (action + extra).replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        let file = cacheDir.appendingPathComponent(name + ".json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 6 * 60 * 60,
           let data = try? Data(contentsOf: file),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !root.isEmpty {
            return root
        }
        let url = URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)&action=\(action)\(extra)")!
        let (data, response) = try await Self.detailSession.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Xtream", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if !root.isEmpty { try? data.write(to: file, options: .atomic) }
        return root
    }

    /// First non-empty string among several keys.
    private static func firstString(_ info: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            let value = Lossy.string(info[key])
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return ""
    }

    /// `backdrop_path` arrives as an array or a single string depending on the provider.
    private static func backdrop(_ info: [String: Any]) -> String {
        if let list = info["backdrop_path"] as? [Any] { return list.first.map(Lossy.string) ?? "" }
        return Lossy.string(info["backdrop_path"])
    }

    /// Series details plus every episode, sorted by season then number.
    func seriesDetail(seriesId: Int) async throws -> SeriesInfo {
        let root = try await detailFetch("get_series_info", "&series_id=\(seriesId)")
        let info = root["info"] as? [String: Any] ?? [:]
        var episodes: [Episode] = []
        if let seasons = root["episodes"] as? [String: Any] {
            for (seasonKey, list) in seasons {
                guard let items = list as? [[String: Any]] else { continue }
                // The object key IS the season number in Xtream; providers often omit or
                // flatten the per-episode "season" field to 1.
                let season = Int(seasonKey) ?? Lossy.int(items.first?["season"])
                for item in items {
                    let detail = item["info"] as? [String: Any] ?? [:]
                    episodes.append(Episode(
                        id: Lossy.int(item["id"]),
                        season: season,
                        number: Lossy.int(item["episode_num"]),
                        title: Lossy.string(item["title"]),
                        ext: Lossy.string(item["container_extension"]),
                        plot: Self.firstString(detail, ["plot", "overview"]),
                        still: Self.firstString(detail, ["movie_image", "cover_big"]),
                        durationSeconds: Lossy.int(detail["duration_secs"])))
                }
            }
        }
        episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        var year = String(Self.firstString(info, ["releaseDate", "releasedate"]).prefix(4))
        if year.isEmpty { year = Lossy.string(info["year"]) }
        var out = SeriesInfo(
            plot: Self.firstString(info, ["plot", "overview"]),
            cover: Self.firstString(info, ["cover", "cover_big", "movie_image"]),
            backdrop: Self.backdrop(info),
            year: year,
            genre: Lossy.string(info["genre"]),
            cast: Self.firstString(info, ["cast", "actors"]),
            episodes: episodes)
        out.rating = Lossy.string(info["rating"])
        out.tmdbId = Lossy.int(info["tmdb"]) != 0 ? Lossy.int(info["tmdb"]) : Lossy.int(info["tmdb_id"])
        return out
    }

    /// Movie details including the provider's poster and TMDB id.
    func movieDetail(streamId: Int) async throws -> MovieInfo {
        let root = try await detailFetch("get_vod_info", "&vod_id=\(streamId)")
        let info = root["info"] as? [String: Any] ?? [:]
        var out = MovieInfo(
            plot: Self.firstString(info, ["plot", "description", "overview"]),
            backdrop: Self.backdrop(info),
            year: String(Self.firstString(info, ["releasedate", "releaseDate"]).prefix(4)),
            genre: Lossy.string(info["genre"]),
            cast: Self.firstString(info, ["cast", "actors"]),
            durationSeconds: Lossy.int(info["duration_secs"]))
        out.poster = Self.firstString(info, ["movie_image", "cover_big"])
        out.rating = Lossy.string(info["rating"])
        out.tmdbId = Lossy.int(info["tmdb_id"]) != 0 ? Lossy.int(info["tmdb_id"]) : Lossy.int(info["tmdb"])
        out.trailer = Self.firstString(info, ["youtube_trailer", "trailer"])
        return out
    }
}
