import Foundation

/// On-disk copies of VOD files so a title plays from local storage: instant start,
/// instant seeks inside what is downloaded, and no dependence on the connection once
/// a title is fully down.
///
/// Two tiers with their own limits and lifetimes:
///  - played: the last 10 titles actually played; kept 7 days, renewed every open.
///  - peek:   titles whose page was opened but not played; 20 at most, 30 minutes.
/// Each entry is a sparse file plus a map of which 2 MB chunks are present, so a
/// partial download is still usable for the parts that exist.
final class MediaStore {
    static let chunkSize = 2 * 1024 * 1024

    enum Tier: String, Codable { case played, peek }

    final class Entry: Codable {
        let id: String            // stable key for the remote URL
        let remoteURL: URL
        var tier: Tier
        var lastOpened: Double    // seconds since 1970
        var totalLength: Int64    // 0 until the first response tells us
        var chunks: [Bool]        // index = chunk number
        /// Where playback last was, so a prefetch resumes from the right place.
        var cursorChunk: Int

        init(id: String, remoteURL: URL, tier: Tier) {
            self.id = id; self.remoteURL = remoteURL; self.tier = tier
            lastOpened = Date().timeIntervalSince1970
            totalLength = 0; chunks = []; cursorChunk = 0
        }

        var chunkCount: Int { totalLength > 0 ? Int((totalLength + Int64(MediaStore.chunkSize) - 1) / Int64(MediaStore.chunkSize)) : 0 }
        var complete: Bool { totalLength > 0 && chunks.count == chunkCount && chunks.allSatisfy { $0 } }
        var cachedBytes: Int64 { Int64(chunks.filter { $0 }.count) * Int64(MediaStore.chunkSize) }
        func has(chunk: Int) -> Bool { chunks.indices.contains(chunk) && chunks[chunk] }

        /// First missing chunk at or after `from`, nil when everything after it is present.
        func nextMissing(from: Int) -> Int? {
            guard chunkCount > 0 else { return from }
            var i = max(0, from)
            while i < chunkCount { if !has(chunk: i) { return i }; i += 1 }
            return nil
        }
    }

    let directory: URL
    private let indexFile: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// The title VLC is reading right now: never evicted, whatever else needs room.
    var playingId: String? {
        get { lock.lock(); defer { lock.unlock() }; return playingIdLocked }
        set { lock.lock(); playingIdLocked = newValue; lock.unlock() }
    }
    private var playingIdLocked: String?
    private var persistScheduled = false
    private let persistQueue = DispatchQueue(label: "media.store.persist")

    static let playedLimit = 10
    static let peekLimit = 20
    static let playedTTL: TimeInterval = 7 * 24 * 3600
    static let peekTTL: TimeInterval = 30 * 60
    /// Never fill the device: leave this much free.
    static let keepFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        indexFile = support.appendingPathComponent("media_index.json")
        // Earlier builds could store a provider error clip as file data; start clean once.
        if UserDefaults.standard.integer(forKey: "media_store_version") < 2 {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: indexFile)
            UserDefaults.standard.set(2, forKey: "media_store_version")
        }
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // Drop entries whose file vanished (the system may purge Caches) and any
            // left over from an older keying scheme.
            entries = saved.filter {
                FileManager.default.fileExists(atPath: self.file(for: $0.value).path) && $0.key == Self.key(for: $0.value.remoteURL)
                    // A "file" smaller than any film is the provider's refusal clip.
                    && ($0.value.totalLength == 0 || $0.value.totalLength >= MediaDownloader.minimumFileBytes)
            }
        }
        // Files nothing in the index claims are dead weight.
        let claimed = Set(entries.keys.map { $0 + ".bin" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !claimed.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        sweep()
    }

    /// Stable across launches (Swift's Hasher is seeded per process): FNV-1a over the URL.
    static func key(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(hash, radix: 36)
    }

    func file(for entry: Entry) -> URL { directory.appendingPathComponent(entry.id + ".bin") }

    func entryList() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values)
    }

    func entry(for url: URL) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.key(for: url)]
    }

    /// The entry for a URL, created in `tier` when new. Opening renews the lifetime
    /// and a play promotes a peek entry to the played tier.
    func open(_ url: URL, tier: Tier) -> Entry {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(for: url)
        let entry = entries[key] ?? Entry(id: key, remoteURL: url, tier: tier)
        entry.lastOpened = Date().timeIntervalSince1970
        if tier == .played { entry.tier = .played }
        entries[key] = entry
        if !FileManager.default.fileExists(atPath: file(for: entry).path) {
            FileManager.default.createFile(atPath: file(for: entry).path, contents: nil)
        }
        persistLocked()
        sweepLocked()
        return entry
    }

    func markChunk(_ chunk: Int, of entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if entry.chunks.count < entry.chunkCount { entry.chunks += Array(repeating: false, count: entry.chunkCount - entry.chunks.count) }
        if entry.chunks.indices.contains(chunk) { entry.chunks[chunk] = true }
        persistLocked()
    }

    func setTotalLength(_ length: Int64, of entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard entry.totalLength != length else { return }
        entry.totalLength = length
        entry.chunks = Array(repeating: false, count: entry.chunkCount)
        persistLocked()
    }

    func setCursor(_ chunk: Int, of entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entry.cursorChunk = chunk
    }

    /// Free space on the volume minus the headroom we always keep.
    func spareBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return free - Self.keepFreeBytes
    }

    /// Make room for `bytes` by dropping peek entries and, only when the fill is for a
    /// title being played, the oldest played ones. The title being filled and the one
    /// VLC is reading are never victims. Returns false when it still cannot fit.
    func makeRoom(bytes: Int64, protected: String, forPlayback: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if spareBytes() >= bytes { return true }
        let victims = entries.values
            .filter { $0.id != protected && $0.id != playingIdLocked && (forPlayback || $0.tier == .peek) }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier == .peek }
                return a.lastOpened < b.lastOpened
            }
        for victim in victims {
            removeLocked(victim)
            if spareBytes() >= bytes { return true }
        }
        return spareBytes() >= bytes
    }

    func sweep() { lock.lock(); sweepLocked(); lock.unlock() }

    // MARK: Internals (call with the lock held)

    private func sweepLocked() {
        let now = Date().timeIntervalSince1970
        for entry in Array(entries.values) {
            let ttl = entry.tier == .played ? Self.playedTTL : Self.peekTTL
            if now - entry.lastOpened > ttl { removeLocked(entry) }
        }
        for tier in [Tier.played, .peek] {
            let limit = tier == .played ? Self.playedLimit : Self.peekLimit
            let inTier = entries.values.filter { $0.tier == tier }.sorted { $0.lastOpened > $1.lastOpened }
            for extra in inTier.dropFirst(limit) { removeLocked(extra) }
        }
        persistLocked()
    }

    private func removeLocked(_ entry: Entry) {
        try? FileManager.default.removeItem(at: file(for: entry))
        entries[entry.id] = nil
    }

    /// Write the index soon, not on every chunk: with thousands of chunks per title the
    /// encode is real work and it must not hold the lock while a chunk is served.
    private func persistLocked() {
        guard !persistScheduled else { return }
        persistScheduled = true
        persistQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.persistNow() }
    }

    private func persistNow() {
        lock.lock()
        persistScheduled = false
        let snapshot = try? JSONEncoder().encode(entries)
        lock.unlock()
        if let snapshot { try? snapshot.write(to: indexFile, options: .atomic) }
    }
}
