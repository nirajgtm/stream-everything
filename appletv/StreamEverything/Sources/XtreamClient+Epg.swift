import Foundation

/// One programme in a channel's guide. Times are the server's own "yyyy-MM-dd HH:mm:ss"
/// strings, shown as-is like the Android app does (providers rarely state a zone).
struct EpgProgram: Hashable {
    let title: String
    let description: String
    let start: String
    let end: String
    let nowPlaying: Bool

    /// "HH:mm" from the end stamp, for "until 21:30".
    var endClock: String { String(end.suffix(8).prefix(5)) }
    var startClock: String { String(start.suffix(8).prefix(5)) }
}

/// Now/next plus the full day table from the Xtream EPG endpoints. Results are kept
/// ~10 minutes so a channel list can re-render without hitting the server per row.
extension XtreamClient {

    /// Cache shared by every client instance; keyed by stream id.
    private actor EpgCache {
        static let shared = EpgCache()
        private var entries: [Int: (fetchedAt: Date, programs: [EpgProgram])] = [:]
        private var inFlight: [Int: Task<[EpgProgram], Never>] = [:]
        private let ttl: TimeInterval = 10 * 60

        func fresh(_ id: Int) -> [EpgProgram]? {
            guard let hit = entries[id], Date().timeIntervalSince(hit.fetchedAt) < ttl else { return nil }
            return hit.programs
        }

        /// Runs `load` once per channel even when many rows ask at the same moment.
        func programs(for id: Int, load: @escaping @Sendable () async -> [EpgProgram]) async -> [EpgProgram] {
            if let hit = fresh(id) { return hit }
            if let task = inFlight[id] { return await task.value }
            let task = Task { await load() }
            inFlight[id] = task
            let result = await task.value
            entries[id] = (Date(), result)
            inFlight[id] = nil
            return result
        }
    }

    /// Non-blocking cache read so rows can render a known guide line instantly.
    func shortEpgCached(streamId: Int) async -> [EpgProgram]? {
        await EpgCache.shared.fresh(streamId)
    }

    /// Now/next for a channel (get_short_epg, up to 4 listings). Empty when the
    /// provider has no guide; never throws so a missing guide cannot break a row.
    func shortEpg(streamId: Int) async -> [EpgProgram] {
        let url = epgUrl("get_short_epg", "&stream_id=\(streamId)&limit=4")
        return await EpgCache.shared.programs(for: streamId) { [url] in
            await Self.loadPrograms(from: url)
        }
    }

    /// The whole guide table for a channel (get_simple_data_table). Not cached: it is
    /// large and only requested when a guide screen is opened on purpose.
    func fullEpg(streamId: Int) async -> [EpgProgram] {
        await Self.loadPrograms(from: epgUrl("get_simple_data_table", "&stream_id=\(streamId)"))
    }

    /// Channels the provider offers catch-up for, read from the on-disk live catalog
    /// the base client already caches. `Entry` carries no archive flag, so this is
    /// how the row's "catch-up" marker is decided without another download.
    func archiveChannelIds() async -> Set<Int> {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("live.json")
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return Set<Int>() }
            var out = Set<Int>()
            for item in items where Lossy.int(item["tv_archive"]) > 0 {
                out.insert(Lossy.int(item["stream_id"]))
            }
            return out
        }.value
    }

    // MARK: Internals

    private func epgUrl(_ action: String, _ extra: String) -> URL {
        URL(string: "\(server)/player_api.php?username=\(user)&password=\(pass)&action=\(action)\(extra)")!
    }

    private static func loadPrograms(from url: URL) async -> [EpgProgram] {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listings = root["epg_listings"] as? [[String: Any]] else { return [] }
        var out: [EpgProgram] = []
        for item in listings {
            let title = decodeBase64Text(Lossy.string(item["title"]))
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            out.append(EpgProgram(
                title: title,
                description: decodeBase64Text(Lossy.string(item["description"])),
                start: Lossy.string(item["start"]),
                end: Lossy.string(item["end"]),
                nowPlaying: Lossy.string(item["now_playing"]) == "1"))
        }
        return out
    }

    /// Xtream sends titles base64-encoded; some servers send plain text, so fall back
    /// to the raw value when decoding fails.
    private static func decodeBase64Text(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return raw
    }
}

extension Array where Element == EpgProgram {
    /// The programme on air now (flagged by the server, else the first listed).
    var current: EpgProgram? { first { $0.nowPlaying } ?? first }

    /// The programme after the current one.
    var upcoming: EpgProgram? {
        guard let now = current, let index = firstIndex(of: now), index + 1 < count else { return nil }
        return self[index + 1]
    }

    /// "Now: title  (until HH:mm)\nNext: title", or "No guide" when empty.
    var nowNextLine: String {
        var line = ""
        if let now = current { line += "Now: \(now.title)  (until \(now.endClock))" }
        if let next = upcoming { line += "\nNext: \(next.title)" }
        return line.isEmpty ? "No guide" : line
    }
}
