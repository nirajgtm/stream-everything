import Foundation

/// Talks to the Xtream Codes API and keeps each catalog on disk so a launch reads
/// from the cache and only refreshes when the copy on disk is older than a day.
final class XtreamClient {
    let server: String
    let user: String
    let pass: String
    private let session: URLSession
    private let cacheDir: URL
    private let refreshAfter: TimeInterval = 24 * 60 * 60

    init(server: String, user: String, pass: String) {
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        self.user = user
        self.pass = pass
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Stream URLs

    func liveUrl(_ entry: Entry) -> URL {
        URL(string: "\(server)/live/\(user)/\(pass)/\(entry.id).ts")!
    }

    func movieUrl(_ entry: Entry) -> URL {
        URL(string: "\(server)/movie/\(user)/\(pass)/\(entry.id).\(entry.ext.isEmpty ? "mkv" : entry.ext)")!
    }

    func episodeUrl(_ episode: Episode) -> URL {
        URL(string: "\(server)/series/\(user)/\(pass)/\(episode.id).\(episode.ext.isEmpty ? "mkv" : episode.ext)")!
    }

    // MARK: API

    private func apiUrl(_ action: String, _ extra: String = "") -> URL {
        URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)&action=\(action)\(extra)")!
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Xtream", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    /// Validates the account. Throws when the server refuses the credentials.
    func checkAccount() async throws -> (active: Bool, connections: String) {
        let data = try await fetch(URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)")!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["user_info"] as? [String: Any] else { return (false, "") }
        let auth = Lossy.int(info["auth"]) == 1
        let cons = "\(Lossy.string(info["active_cons"]))/\(Lossy.string(info["max_connections"]))"
        return (auth, cons)
    }

    private func catalogName(_ kind: Kind) -> String {
        switch kind { case .live: "live"; case .movie: "vod"; case .series: "series" }
    }
    private func catalogAction(_ kind: Kind) -> String {
        switch kind { case .live: "get_live_streams"; case .movie: "get_vod_streams"; case .series: "get_series" }
    }
    private func jsonFile(_ kind: Kind) -> URL { cacheDir.appendingPathComponent("\(catalogName(kind)).json") }
    private func binaryFile(_ kind: Kind) -> URL { cacheDir.appendingPathComponent("\(catalogName(kind)).bin") }

    /// Age of the JSON copy on disk; nil when there is none.
    func catalogAge(_ kind: Kind) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonFile(kind).path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// True when the copy on disk is missing or older than a day.
    func catalogIsStale(_ kind: Kind) -> Bool {
        guard let age = catalogAge(kind) else { return true }
        return age > refreshAfter
    }

    func hasCachedCatalogs() -> Bool {
        Kind.allCases.allSatisfy { FileManager.default.fileExists(atPath: binaryFile($0).path) }
    }

    /// The parsed catalog from the binary cache, or nil when there is none yet.
    func cachedCatalog(_ kind: Kind) -> [Entry]? {
        CatalogBinaryCache.read(from: binaryFile(kind))
    }

    /// Download the catalog (or re-parse a fresh JSON copy), write the binary cache,
    /// and return the entries. This is the slow path: network plus a full parse.
    func downloadCatalog(_ kind: Kind) async throws -> [Entry] {
        let file = jsonFile(kind)
        var data: Data? = nil
        if let age = catalogAge(kind), age < refreshAfter, let onDisk = try? Data(contentsOf: file), onDisk.count > 2 {
            data = onDisk   // fresh JSON without a binary yet (first run after an update)
        }
        if data == nil {
            let fetched = try await fetch(apiUrl(catalogAction(kind)))
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        }
        let entries = parseCatalog(kind, data!)
        CatalogBinaryCache.write(entries, to: binaryFile(kind))
        return entries
    }

    /// Cached when available, otherwise downloaded. Kept for callers that just want entries.
    func catalog(_ kind: Kind, forceRefresh: Bool = false) async throws -> [Entry] {
        if !forceRefresh, let cached = cachedCatalog(kind) { return cached }
        return try await downloadCatalog(kind)
    }

    private func parseCatalog(_ kind: Kind, _ data: Data) -> [Entry] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        out.reserveCapacity(items.count)
        for item in items {
            let name = Lossy.string(item["name"])
            let id = Lossy.int(kind == .series ? item["series_id"] : item["stream_id"])
            if name.isEmpty || id == 0 { continue }
            out.append(Entry(
                kind: kind, name: name, id: id,
                ext: Lossy.string(item["container_extension"]),
                logo: Lossy.string(kind == .series ? item["cover"] : item["stream_icon"]),
                categoryId: Lossy.string(item["category_id"]),
                epgId: Lossy.string(item["epg_channel_id"]),
                archive: Lossy.int(item["tv_archive"])))
        }
        return out
    }

    /// Category lists are small; the JSON copy is kept a day like the catalogs.
    private func catalogData(_ action: String, name: String, forceRefresh: Bool) async throws -> Data {
        let file = cacheDir.appendingPathComponent("\(name).json")
        if !forceRefresh, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < refreshAfter,
           let data = try? Data(contentsOf: file), data.count > 2 {
            return data
        }
        let data = try await fetch(apiUrl(action))
        try? data.write(to: file, options: .atomic)
        return data
    }

    func categories(_ kind: Kind) async throws -> [ChannelCategory] {
        let action = switch kind {
            case .live: "get_live_categories"
            case .movie: "get_vod_categories"
            case .series: "get_series_categories"
        }
        let data = try await catalogData(action, name: "\(action)", forceRefresh: false)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.map { ChannelCategory(id: Lossy.string($0["category_id"]), name: Lossy.string($0["category_name"])) }
            .filter { !$0.id.isEmpty && !AdultFilter.isAdultCategory($0.name) }
    }

    func seriesInfo(seriesId: Int) async throws -> SeriesInfo {
        let data = try await fetch(apiUrl("get_series_info", "&series_id=\(seriesId)"))
        let root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let info = root["info"] as? [String: Any] ?? [:]
        var episodes: [Episode] = []
        if let seasons = root["episodes"] as? [String: Any] {
            for (seasonKey, list) in seasons {
                guard let items = list as? [[String: Any]] else { continue }
                let season = Int(seasonKey) ?? Lossy.int(items.first?["season"])
                for item in items {
                    let detail = item["info"] as? [String: Any] ?? [:]
                    episodes.append(Episode(
                        id: Lossy.int(item["id"]),
                        season: season,
                        number: Lossy.int(item["episode_num"]),
                        title: Lossy.string(item["title"]),
                        ext: Lossy.string(item["container_extension"]),
                        plot: Lossy.string(detail["plot"]),
                        still: Lossy.string(detail["movie_image"]),
                        durationSeconds: Lossy.int(detail["duration_secs"])))
                }
            }
        }
        episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        return SeriesInfo(
            plot: Lossy.string(info["plot"]),
            cover: Lossy.string(info["cover"]),
            backdrop: (info["backdrop_path"] as? [Any])?.first.map(Lossy.string) ?? "",
            year: String(Lossy.string(info["releaseDate"]).prefix(4)),
            genre: Lossy.string(info["genre"]),
            cast: Lossy.string(info["cast"]),
            episodes: episodes)
    }

    func movieInfo(streamId: Int) async throws -> MovieInfo {
        let data = try await fetch(apiUrl("get_vod_info", "&vod_id=\(streamId)"))
        let root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let info = root["info"] as? [String: Any] ?? [:]
        return MovieInfo(
            plot: Lossy.string(info["plot"]),
            backdrop: (info["backdrop_path"] as? [Any])?.first.map(Lossy.string) ?? "",
            year: String(Lossy.string(info["releasedate"]).prefix(4)),
            genre: Lossy.string(info["genre"]),
            cast: Lossy.string(info["cast"]),
            durationSeconds: Lossy.int(info["duration_secs"]))
    }
}

/// Xtream servers send numbers as strings and strings as numbers; read either.
enum Lossy {
    static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
    static func int(_ value: Any?) -> Int {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }
}
