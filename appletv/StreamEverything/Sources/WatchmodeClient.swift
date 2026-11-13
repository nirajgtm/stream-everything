import Foundation

/// Watchmode reader used to reorder provider rails by accurate per-service
/// popularity (JustWatch based). The free tier is 2500 requests a month, so
/// responses are cached 24h (nothing is fetched twice a day) and a monthly budget
/// guard stops calling well before the cap; callers then fall back to TMDB order.
final class WatchmodeClient {
    private let key: String
    var configured: Bool { !key.isEmpty }

    private let session: URLSession
    private let cacheDir: URL
    private let budgetFile: URL
    private let timeToLive: TimeInterval = 24 * 60 * 60
    /// Leaves headroom under the 2500 quota.
    private let monthlyCap = 2200
    private let budgetLock = NSLock()

    init(key: String = Credentials.watchmodeKey) {
        self.key = key
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watchmode", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        budgetFile = cacheDir.appendingPathComponent("watchmode_budget.json")
    }

    // MARK: Monthly budget

    private func currentMonth() -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private func readBudget() -> (month: String, count: Int) {
        guard let data = try? Data(contentsOf: budgetFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("", 0) }
        return (Lossy.string(root["month"]), Lossy.int(root["count"]))
    }

    private func withinBudget() -> Bool {
        budgetLock.lock(); defer { budgetLock.unlock() }
        let budget = readBudget()
        if budget.month != currentMonth() { return true }   // new month resets implicitly
        return budget.count < monthlyCap
    }

    private func recordCall() {
        budgetLock.lock(); defer { budgetLock.unlock() }
        let month = currentMonth()
        let budget = readBudget()
        let count = budget.month == month ? budget.count : 0
        if let data = try? JSONSerialization.data(withJSONObject: ["month": month, "count": count + 1]) {
            try? data.write(to: budgetFile, options: .atomic)
        }
    }

    // MARK: Ranks

    /// Popular-order ranks for a source (home rail + hub Popular Movies/Shows).
    func popularRanks(sourceId: Int) async -> [Int: Int] {
        await ranks("src_\(sourceId)", sourceId: sourceId, params: ["types": "movie,tv_series", "sort_by": "popularity_desc"])
    }

    /// Newest-first ranks for a source (hub "New on X").
    func newRanks(sourceId: Int) async -> [Int: Int] {
        await ranks("new_\(sourceId)", sourceId: sourceId, params: ["types": "movie,tv_series", "sort_by": "release_date_desc"])
    }

    /// Popular ranks within a genre on a source (hub genre rows).
    func genreRanks(sourceId: Int, watchmodeGenreId: Int) async -> [Int: Int] {
        guard watchmodeGenreId != 0 else { return [:] }
        return await ranks("g\(watchmodeGenreId)_\(sourceId)", sourceId: sourceId,
                           params: ["types": "movie,tv_series", "genres": "\(watchmodeGenreId)", "sort_by": "popularity_desc"])
    }

    /// Reorders TMDB items by a Watchmode rank map; items Watchmode does not know
    /// keep their TMDB order after the ranked ones. Empty ranks leave the list as is.
    func reorder(_ items: [TmdbItem], by ranks: [Int: Int]) -> [TmdbItem] {
        guard !ranks.isEmpty else { return items }
        let indexed = items.enumerated()
        return indexed.sorted { a, b in
            let ra = ranks[a.element.tmdbId], rb = ranks[b.element.tmdbId]
            switch (ra, rb) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { $0.element }
    }

    /// tmdbId -> rank (0 = first) from a Watchmode list-titles query. Cached 24h on
    /// disk; empty on any error, a missing key, or an exhausted monthly budget, so
    /// callers keep TMDB ordering.
    private func ranks(_ cacheKey: String, sourceId: Int, params: [String: String]) async -> [Int: Int] {
        guard configured, sourceId != 0 else { return [:] }
        let file = cacheDir.appendingPathComponent("wm_\(cacheKey).json")
        var body: Data?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < timeToLive {
            body = try? Data(contentsOf: file)
        } else {
            guard withinBudget() else { return [:] }
            var components = URLComponents(string: "https://api.watchmode.com/v1/list-titles/")!
            var items = [
                URLQueryItem(name: "apiKey", value: key),
                URLQueryItem(name: "source_ids", value: "\(sourceId)"),
                URLQueryItem(name: "regions", value: "US"),
                URLQueryItem(name: "limit", value: "50")
            ]
            for (name, value) in params.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: name, value: value)) }
            components.queryItems = items
            guard let url = components.url,
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
            recordCall()
            try? data.write(to: file, options: .atomic)
            body = data
        }
        guard let body,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let titles = root["titles"] as? [[String: Any]] else { return [:] }
        var out: [Int: Int] = [:]
        var rank = 0
        for title in titles {
            let id = Lossy.int(title["tmdb_id"])
            if id == 0 || out[id] != nil { continue }
            out[id] = rank
            rank += 1
        }
        return out
    }
}
