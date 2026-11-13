import Foundation

/// The app's one network client for VOD bytes. Holds a single long-lived connection,
/// the way a player does, and reads the file sequentially into 2 MB chunks of the
/// MediaStore; it reconnects only when the bytes needed next are somewhere else
/// (a seek, a different title). The provider counts every new connection against
/// the account's single slot and keeps a closed one on the books for a moment, so
/// reconnects are rate limited and never fired back to back.
///
/// Order of service: what the player is waiting for, then the rest of the playing
/// title. Prefetch of other titles (a page or tile the viewer rested on, the next
/// episode) only runs when nothing is playing or the playing title is fully on disk:
/// the head first (file tail plus the first chunks, so it opens at once), then the
/// rest up to its cap.
final class MediaDownloader: NSObject, URLSessionDataDelegate {
    private let store: MediaStore
    private var session: URLSession!
    private let queue = DispatchQueue(label: "media.downloader")
    private let userAgent = "VLC/3.0.20 LibVLC/3.0.20"

    /// Chunks something is waiting for, most urgent first.
    private var demands: [(entry: MediaStore.Entry, chunk: Int)] = []
    /// The title being played: filled completely, right behind the playhead.
    private var playingEntry: MediaStore.Entry?
    private var playingFrom = 0
    /// True while a player screen is up: prefetch of anything else waits.
    private var playbackActive = false
    /// Background fill of a title nobody is playing yet; capped so a browse never
    /// eats the storage.
    private var prefetchEntry: MediaStore.Entry?
    private var prefetchFrom = 0
    private var prefetchStartChunk = 0
    private var prefetchCapChunks = Int.max
    /// A prefetch asked for while another is still fetching its head: it takes over
    /// once that head is in, so a browse does not churn connections.
    private var queuedPrefetch: (entry: MediaStore.Entry, fraction: Double)?
    /// Live TV, or the app leaving the screen, owns the connection; nothing downloads.
    private var suspended = false
    /// Set when the provider refused (its "connection limit" clip instead of the
    /// file): nothing connects until it passes. Grows with each refusal in a row.
    private var limitedUntil = Date.distantPast
    private var refusals = 0
    private var failures: [String: Int] = [:]
    private let waiters = NSCondition()

    /// The open connection, if any.
    private final class Stream {
        let task: URLSessionDataTask
        let entry: MediaStore.Entry
        /// Next chunk the incoming bytes belong to.
        var chunk: Int
        var buffer = Data()
        var handle: FileHandle?
        init(task: URLSessionDataTask, entry: MediaStore.Entry, chunk: Int) {
            self.task = task; self.entry = entry; self.chunk = chunk
        }
    }
    private var stream: Stream?
    private var lastConnectAt = Date.distantPast
    private var lastDemandAt = Date.distantPast
    /// Until this passes, the playing title's fill waits for the player's own requests.
    private var playbackHoldUntil = Date.distantPast
    /// Cancelled tasks that have not reported completion yet.
    private var closingTasks: Set<ObjectIdentifier> = []
    private let closing = NSCondition()

    /// A prefetch of a title not yet played stops after this much.
    static let peekCapBytes: Int64 = 200 * 1024 * 1024
    /// Enough of a prefetch to start playing: the container index (mp4 moov, mkv cues
    /// usually sit at the end) and the first `headChunks` from the start point.
    static let headChunks = 12
    /// Minimum spacing between new connections to the provider.
    static let connectGap: TimeInterval = 1.2
    /// Reading through this many already-cached chunks beats a reconnect.
    static let readThroughChunks = 8
    /// A player probing a file fires several seeks within a moment (head, index,
    /// resume point); wait this long after the last one before connecting, so the
    /// burst costs one connection, not one each.
    static let settle: TimeInterval = 0.3
    /// No film or episode is smaller than this; the provider's refusal clip is.
    static let minimumFileBytes: Int64 = 30 * 1024 * 1024

    init(store: MediaStore) {
        self.store = store
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: Requests

    /// Background fill of `entry` starting at `chunk`. Replaces an earlier prefetch
    /// unless that one is still pulling its head, in which case it waits its turn.
    /// A peek entry stops after `peekCapBytes`; a played one runs to the end.
    func prefetch(_ entry: MediaStore.Entry, fromFraction fraction: Double) {
        queue.async {
            if let current = self.prefetchEntry, current.id != entry.id, self.prefetchHead(current) != nil {
                self.queuedPrefetch = (entry, fraction)
            } else {
                self.startPrefetch(entry, fromFraction: fraction)
            }
            self.pump()
        }
    }

    /// The start point is a fraction of the file: the size is not known for a fresh
    /// title until its first response, which is the prefetch's own first connection.
    private var prefetchFraction = 0.0

    private func startPrefetch(_ entry: MediaStore.Entry, fromFraction fraction: Double) {
        prefetchEntry = entry
        prefetchFraction = fraction
        prefetchFrom = 0
        prefetchStartChunk = 0
        prefetchCapChunks = entry.tier == .peek ? Int(Self.peekCapBytes / Int64(MediaStore.chunkSize)) : Int.max
        queuedPrefetch = nil
        resolvePrefetchStart()
    }

    /// Once the size is known, place the start point.
    private func resolvePrefetchStart() {
        guard let entry = prefetchEntry, entry.chunkCount > 0, prefetchFraction > 0 else { return }
        let chunk = min(entry.chunkCount - 1, Int(Double(entry.chunkCount) * prefetchFraction))
        prefetchStartChunk = chunk
        prefetchFrom = max(prefetchFrom, chunk)
        prefetchFraction = 0
    }

    func stopPrefetch() { queue.async { self.prefetchEntry = nil; self.queuedPrefetch = nil; self.pump() } }

    /// VLC is about to read `entry`: it is the title to fill from now on, nothing else
    /// downloads while the player is up, and whatever an earlier request was still
    /// waiting on is dropped.
    func beginPlayback(of entry: MediaStore.Entry) {
        store.playingId = entry.id
        queue.async {
            self.playbackActive = true
            self.demands.removeAll { $0.entry.id != entry.id }
            if self.playingEntry?.id != entry.id {
                self.playingEntry = entry
                self.playingFrom = entry.cursorChunk
            }
            self.failures[entry.id] = 0
            // The player's first requests (head, index, start point) arrive within a
            // moment and decide where the connection should go; do not jump ahead.
            self.playbackHoldUntil = Date().addingTimeInterval(1.5)
            self.pump()
        }
    }

    /// A player screen came up or went away. While one is up only its title downloads.
    func setPlaybackActive(_ on: Bool) {
        if !on { store.playingId = nil }
        queue.async {
            self.playbackActive = on
            self.pump()
        }
    }

    /// Hold every download or let them run again. Suspending is synchronous and
    /// closes the connection so the provider sees the slot released before anything
    /// else connects.
    func setSuspended(_ on: Bool) {
        var hadStream = false
        queue.sync {
            self.suspended = on
            if on { hadStream = self.stream != nil; self.closeStream() } else { self.pump() }
        }
        guard on else { return }
        // Wait for the cancel to finish so the provider has seen the close, then a
        // beat for its accounting, before the live player connects.
        closing.lock()
        let deadline = Date().addingTimeInterval(2)
        while !closingTasks.isEmpty, closing.wait(until: deadline) {}
        closing.unlock()
        if hadStream { Thread.sleep(forTimeInterval: 0.8) }
    }

    /// Block until `chunk` of `entry` is on disk, or give up after `timeout` or once
    /// `stillWanted` says the reader went away (its demand is withdrawn so the
    /// connection is not steered to bytes nobody reads). A playback demand also makes
    /// `entry` the title to fill behind the playhead.
    func ensure(_ entry: MediaStore.Entry, chunk: Int, timeout: TimeInterval = 60,
                forPlayback: Bool = true, stillWanted: (() -> Bool)? = nil) -> Bool {
        if entry.has(chunk: chunk) { return true }
        queue.async {
            if !self.demands.contains(where: { $0.entry.id == entry.id && $0.chunk == chunk }) {
                self.demands.insert((entry, chunk), at: 0)
                self.lastDemandAt = Date()
            }
            if forPlayback {
                // Keep filling behind the playhead afterwards.
                self.playingEntry = entry
                self.playingFrom = chunk + 1
            }
            self.pump()
        }
        let deadline = Date().addingTimeInterval(timeout)
        waiters.lock(); defer { waiters.unlock() }
        while !entry.has(chunk: chunk) {
            if let stillWanted, !stillWanted() {
                queue.async { self.demands.removeAll { $0.entry.id == entry.id && $0.chunk == chunk }; self.pump() }
                return false
            }
            if !waiters.wait(until: min(deadline, Date().addingTimeInterval(0.25))), Date() >= deadline { return false }
        }
        return true
    }

    /// Total length of `entry`, fetching chunk 0 first when unknown.
    func totalLength(of entry: MediaStore.Entry, forPlayback: Bool = true) -> Int64 {
        if entry.totalLength > 0 { return entry.totalLength }
        _ = ensure(entry, chunk: 0, timeout: 30, forPlayback: forPlayback)
        return entry.totalLength
    }

    // MARK: Scheduling (on `queue`)

    /// Steer the connection: keep it when it is delivering what is wanted next,
    /// otherwise close it and open one where the bytes are.
    private func pump() {
        guard !suspended else { closeStream(); return }
        if Date() < limitedUntil { schedulePump(after: limitedUntil.timeIntervalSinceNow + 0.1); return }
        let wanted = nextWanted()
        if let stream {
            guard let wanted else { closeStream(); return }
            if wanted.entry.id == stream.entry.id {
                let ahead = wanted.chunk - stream.chunk
                if ahead >= 0 && ahead <= Self.readThroughChunks { return }   // let it flow
            }
            closeStream()
        }
        guard let wanted else { return }
        let sinceLast = Date().timeIntervalSince(lastConnectAt)
        if sinceLast < Self.connectGap { schedulePump(after: Self.connectGap - sinceLast); return }
        let sinceDemand = Date().timeIntervalSince(lastDemandAt)
        if sinceDemand < Self.settle { schedulePump(after: Self.settle - sinceDemand); return }
        open(wanted.entry, at: wanted.chunk)
    }

    /// Run the pump after `delay`; an earlier pending run is kept, a later one is
    /// replaced, so a short wait is never swallowed by a long one already queued.
    private var pendingPump: (work: DispatchWorkItem, at: Date)?

    private func schedulePump(after delay: TimeInterval) {
        let at = Date().addingTimeInterval(max(0.05, delay))
        if let pending = pendingPump {
            if pending.at <= at { return }
            pending.work.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPump = nil
            self?.pump()
        }
        pendingPump = (work, at)
        queue.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    private func nextWanted() -> (entry: MediaStore.Entry, chunk: Int)? {
        while let first = demands.first {
            if first.entry.has(chunk: first.chunk) { demands.removeFirst(); continue }
            return first
        }
        if playbackActive {
            // Playback owns the connection: the playing title fills behind the playhead
            // and other titles wait until it is whole (then the connection is free
            // anyway) or the player is gone.
            if let next = playingFill() { return next }
            if playingEntry != nil { return nil }
            return prefetchNext()
        }
        // Nothing playing: the page in front of the viewer owns the connection (its
        // head, then up to its cap); the last played title goes on filling only when
        // nothing else is wanted, so browsing never bounces between the two.
        return prefetchNext() ?? playingFill()
    }

    /// Next chunk of the title being (or last) played, filling behind the playhead.
    private func playingFill() -> (entry: MediaStore.Entry, chunk: Int)? {
        guard let entry = playingEntry, (failures[entry.id] ?? 0) < 5 else { return nil }
        let hold = playbackHoldUntil.timeIntervalSinceNow
        if hold > 0 {
            // Waiting for the player: a connection already on this title keeps flowing.
            schedulePump(after: hold)
            if let stream, stream.entry.id == entry.id { return (entry, stream.chunk) }
            return nil
        }
        if let next = entry.nextMissing(from: playingFrom) ?? entry.nextMissing(from: 0) {
            guard store.makeRoom(bytes: Int64(MediaStore.chunkSize) * 4, protected: entry.id, forPlayback: true) else { return nil }
            return (entry, next)
        }
        playingEntry = nil
        return nil
    }

    /// Next chunk of the prefetch: its head, a queued prefetch's head once that is in,
    /// then the rest up to the cap.
    private func prefetchNext() -> (entry: MediaStore.Entry, chunk: Int)? {
        guard var entry = prefetchEntry, (failures[entry.id] ?? 0) < 5 else {
            if let queued = queuedPrefetch { startPrefetch(queued.entry, fromFraction: queued.fraction); return prefetchNext() }
            return nil
        }
        if let head = prefetchHead(entry) { return head }
        if let queued = queuedPrefetch, queued.entry.id != entry.id {
            startPrefetch(queued.entry, fromFraction: queued.fraction)
            entry = queued.entry
            if let head = prefetchHead(entry) { return head }
        }
        let room = Int64(MediaStore.chunkSize) * 4
        guard let next = entry.nextMissing(from: prefetchFrom), next - prefetchStartChunk < prefetchCapChunks,
              store.makeRoom(bytes: room, protected: entry.id, forPlayback: false) else { prefetchEntry = nil; return nil }
        return (entry, next)
    }

    /// The head from the start point first (the size probe already sits at chunk 0,
    /// so a fresh title continues on that connection), then the tail pair. Nil once
    /// all of it is in.
    private func prefetchHead(_ entry: MediaStore.Entry) -> (entry: MediaStore.Entry, chunk: Int)? {
        guard entry.chunkCount > 0 else { return (entry, 0) }   // size unknown: the first chunk tells
        if entry.id == prefetchEntry?.id { resolvePrefetchStart() }
        var wanted = Array(prefetchStartChunk..<min(entry.chunkCount, prefetchStartChunk + Self.headChunks))
        wanted += [entry.chunkCount - 2, entry.chunkCount - 1]
        guard let chunk = wanted.first(where: { $0 >= 0 && !entry.has(chunk: $0) }) else { return nil }
        guard store.makeRoom(bytes: Int64(MediaStore.chunkSize) * 4, protected: entry.id, forPlayback: false) else { prefetchEntry = nil; return nil }
        return (entry, chunk)
    }

    // MARK: The connection (on `queue`)

    private func open(_ entry: MediaStore.Entry, at chunk: Int) {
        var request = URLRequest(url: entry.remoteURL)
        request.setValue("bytes=\(Int64(chunk) * Int64(MediaStore.chunkSize))-", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        stream = Stream(task: task, entry: entry, chunk: chunk)
        lastConnectAt = Date()
        NSLog("MEDIA connect %@ from chunk %d", entry.id, chunk)
        task.resume()
    }

    private func closeStream() {
        guard let stream else { return }
        closing.lock(); closingTasks.insert(ObjectIdentifier(stream.task)); closing.unlock()
        stream.task.cancel()
        try? stream.handle?.close()
        self.stream = nil
    }

    private func wake() {
        waiters.lock(); waiters.broadcast(); waiters.unlock()
    }

    /// The bytes for one whole chunk arrived: put them on disk and move on.
    private func commit(_ data: Data, chunk: Int, to stream: Stream) {
        if stream.handle == nil { stream.handle = try? FileHandle(forWritingTo: store.file(for: stream.entry)) }
        guard let handle = stream.handle else { return }
        try? handle.seek(toOffset: UInt64(chunk) * UInt64(MediaStore.chunkSize))
        handle.write(data)
        store.markChunk(chunk, of: stream.entry)
        failures[stream.entry.id] = 0
        if stream.entry.id == playingEntry?.id, chunk >= playingFrom { playingFrom = chunk + 1 }
        if stream.entry.id == prefetchEntry?.id, chunk >= prefetchFrom { prefetchFrom = chunk + 1 }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            guard let stream = self.stream, stream.task === dataTask else { completionHandler(.cancel); return }
            let entry = stream.entry
            let start = Int64(stream.chunk) * Int64(MediaStore.chunkSize)
            // Only a 206 whose Content-Range starts where we asked is the file. A plain
            // 200 here is the provider's "connection limit reached" clip (or a server that
            // ignored the range); storing it would poison the cache, so back off instead.
            // A title's size is known after the first response; anything under
            // `minimumFileBytes` is the refusal clip served with a range, not a film.
            if let http = response as? HTTPURLResponse, http.statusCode == 206,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = Self.parseContentRange(range), parsed.start == start,
               entry.totalLength != 0, parsed.total != entry.totalLength, parsed.total >= Self.minimumFileBytes {
                // The provider replaced the file: what we hold is for the old one.
                NSLog("MEDIA %@ size changed %lld -> %lld; cache reset", entry.id, entry.totalLength, parsed.total)
                self.store.setTotalLength(parsed.total, of: entry)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                  let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.parseContentRange(range), parsed.start == start,
                  entry.totalLength == 0 ? parsed.total >= Self.minimumFileBytes : parsed.total == entry.totalLength else {
                var code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 206 { code = 200 }   // a wrong-sized 206 is the refusal clip too
                NSLog("MEDIA %@ chunk %d: HTTP %d %@", entry.id, stream.chunk, code,
                      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? "no range")
                self.closeStream()
                completionHandler(.cancel)
                if code == 200 {
                    // The slot is taken (often our own just-closed connection still on
                    // the books): 2s, 4s, 8s, then 15s between tries.
                    self.refusals += 1
                    let delay = min(15, 2 * Double(1 << max(0, min(self.refusals - 1, 3))))
                    self.limitedUntil = Date().addingTimeInterval(delay)
                    self.schedulePump(after: delay + 0.1)
                } else {
                    // Not there, or the server will not range: this title is broken.
                    self.failures[entry.id, default: 0] += 1
                    self.wake()
                    self.schedulePump(after: 2)
                }
                return
            }
            self.refusals = 0
            if entry.totalLength == 0 { self.store.setTotalLength(parsed.total, of: entry) }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard let stream = self.stream, stream.task === dataTask else { return }
            stream.buffer.append(data)
            var wrote = false
            while stream.buffer.count >= MediaStore.chunkSize {
                self.commit(stream.buffer.prefix(MediaStore.chunkSize), chunk: stream.chunk, to: stream)
                stream.buffer.removeFirst(MediaStore.chunkSize)
                stream.chunk += 1
                wrote = true
            }
            if wrote { self.wake(); self.pump() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closing.lock(); closingTasks.remove(ObjectIdentifier(task)); closing.broadcast(); closing.unlock()
        queue.async {
            guard let stream = self.stream, stream.task === task else { return }
            let entry = stream.entry
            if error == nil {
                // End of file: the last chunk is shorter than the rest.
                let expected = Int(entry.totalLength - Int64(stream.chunk) * Int64(MediaStore.chunkSize))
                if stream.chunk == entry.chunkCount - 1, stream.buffer.count == expected, expected > 0 {
                    self.commit(stream.buffer, chunk: stream.chunk, to: stream)
                }
            } else if (error as? URLError)?.code != .cancelled {
                self.failures[entry.id, default: 0] += 1
                NSLog("MEDIA %@ at chunk %d failed: %@", entry.id, stream.chunk, error!.localizedDescription)
            }
            self.closeStream()
            self.wake()
            self.schedulePump(after: error == nil ? 0.05 : 2)
        }
    }

    /// "bytes 0-2097151/11234567" -> (0, 2097151, 11234567)
    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let body = value.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces)
        guard let slash = body.firstIndex(of: "/"), let dash = body.firstIndex(of: "-") else { return nil }
        guard let start = Int64(body[..<dash]), let end = Int64(body[body.index(after: dash)..<slash]),
              let total = Int64(body[body.index(after: slash)...]) else { return nil }
        return (start, end, total)
    }
}
