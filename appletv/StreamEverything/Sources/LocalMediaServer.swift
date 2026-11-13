import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that VLC plays from. Every byte it serves comes
/// from the MediaStore file; a byte that is not there yet is demanded from the
/// downloader and the response waits for it. VLC therefore never touches the
/// provider itself, and anything already on disk plays at disk speed.
final class LocalMediaServer {
    private let store: MediaStore
    private let downloader: MediaDownloader
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "media.server", attributes: .concurrent)

    init(store: MediaStore, downloader: MediaDownloader) {
        self.store = store
        self.downloader = downloader
        start()
    }

    /// The local URL to hand VLC for a remote VOD file.
    func localURL(for remote: URL) -> URL {
        let entry = store.open(remote, tier: .played)
        downloader.beginPlayback(of: entry)
        ensureListening()
        return URL(string: "http://127.0.0.1:\(port)/media/\(entry.id)")!
    }

    private var ready = false
    private var broken = false
    private let stateLock = NSLock()

    /// The system drops an app's listening sockets while it is in the background;
    /// restart before handing out a URL and whenever the listener reports trouble.
    /// A listener still binding is waited for, not replaced.
    func ensureListening() {
        stateLock.lock()
        let fine = ready && listener != nil
        let dead = broken || listener == nil
        stateLock.unlock()
        // "Ready" is what the listener last said; a network change can kill the socket
        // without a word, so prove it with a real connection before trusting it.
        if fine && probe() { return }
        if fine { NSLog("MEDIA server not answering; restarting") }
        if dead || fine {
            NSLog("MEDIA server not listening; restarting")
            listener?.cancel()
            listener = nil
            start()
        }
        // Give it a moment to bind so the first request does not race the start.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            stateLock.lock(); let ok = ready; stateLock.unlock()
            if ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        NSLog("MEDIA server still not ready")
    }

    /// True when a TCP connection to the server opens within half a second.
    private func probe() -> Bool {
        guard let port = NWEndpoint.Port(rawValue: self.port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; done.signal()
            case .failed, .cancelled: done.signal()
            case .waiting: connection.cancel()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "media.server.probe"))
        _ = done.wait(timeout: .now() + 0.5)
        connection.cancel()
        return ok
    }

    private func start() {
        stateLock.lock(); ready = false; broken = false; stateLock.unlock()
        // Loopback only: VLC is in this process, and a listener on every interface is
        // torn down by the system when Wi-Fi changes, without reporting it.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        for candidate in [UInt16(8713), 8714, 8715, 0] {
            guard let listener = try? NWListener(using: parameters, on: candidate == 0 ? .any : NWEndpoint.Port(rawValue: candidate)!) else { continue }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                // A listener being replaced must not report on behalf of the new one.
                guard let self, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.stateLock.lock(); self.ready = true; self.broken = false; self.stateLock.unlock()
                    self.port = listener?.port?.rawValue ?? candidate
                    NSLog("MEDIA server listening on %d", Int(self.port))
                case .failed(let error):
                    NSLog("MEDIA server failed: %@", error.localizedDescription)
                    self.stateLock.lock(); self.ready = false; self.broken = true; self.stateLock.unlock()
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.ensureListening() }
                case .cancelled:
                    self.stateLock.lock(); self.ready = false; self.broken = true; self.stateLock.unlock()
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            port = candidate
            break
        }
    }

    // MARK: One connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            var buffer = buffer
            buffer.append(data)
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.handle(head: head, on: connection)
            } else if isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n").map(String.init)
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0]), path = String(parts[1])
        guard path.hasPrefix("/media/"), let entry = store.entryById(String(path.dropFirst("/media/".count))) else {
            NSLog("MEDIA 404 for %@", path)
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true); return
        }
        let total = downloader.totalLength(of: entry)
        guard total > 0 else {
            NSLog("MEDIA %@ 503: size still unknown", entry.id)
            send(connection, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true); return
        }
        var from: Int64 = 0
        var to: Int64 = total - 1
        var partial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.firstIndex(of: "=") {
            let spec = rangeLine[rangeLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
            if bounds.count == 2 {
                if let a = Int64(bounds[0]) { from = a; to = Int64(bounds[1]) ?? total - 1 }
                else if let suffix = Int64(bounds[1]) { from = max(0, total - suffix) }
                partial = true
            }
        }
        if from >= total { send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true); return }
        to = min(to, total - 1)
        let length = to - from + 1
        var header = partial ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(to)/\(total)\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
        NSLog("MEDIA %@ %@ range %lld-%lld cached=%d", method, entry.id, from, to, entry.has(chunk: Int(from / Int64(MediaStore.chunkSize))) ? 1 : 0)
        if method == "HEAD" { send(connection, header, close: true); return }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.stream(entry: entry, from: from, to: to, on: connection)
        })
    }

    /// Write bytes from `from` to `to` as they become available, in chunk-sized slices.
    private func stream(entry: MediaStore.Entry, from: Int64, to: Int64, on connection: NWConnection) {
        var position = from
        let file = store.file(for: entry)
        // VLC drops a request the moment it seeks; nothing tells us but the socket
        // closing, so keep a read pending and remember when it ends.
        let closed = ClosedFlag()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
            if isComplete || error != nil { closed.set() }
        }
        queue.async { [weak self] in
            guard let self, let handle = try? FileHandle(forReadingFrom: file) else { connection.cancel(); return }
            defer { try? handle.close() }
            while position <= to {
                if case .cancelled = connection.state { return }
                if case .failed = connection.state { return }
                if closed.isSet { connection.cancel(); return }
                let chunk = Int(position / Int64(MediaStore.chunkSize))
                self.store.setCursor(chunk, of: entry)
                if !entry.has(chunk: chunk) { NSLog("MEDIA wait chunk %d of %@", chunk, entry.id) }
                guard self.downloader.ensure(entry, chunk: chunk, stillWanted: { !closed.isSet }) else {
                    if !closed.isSet { NSLog("MEDIA %@ chunk %d never arrived; dropping the request", entry.id, chunk) }
                    connection.cancel(); return
                }
                let chunkEnd = min(to, Int64(chunk + 1) * Int64(MediaStore.chunkSize) - 1)
                let count = Int(chunkEnd - position + 1)
                try? handle.seek(toOffset: UInt64(position))
                guard let data = try? handle.read(upToCount: count), data.count == count else { connection.cancel(); return }
                let semaphore = DispatchSemaphore(value: 0)
                var failed = false
                connection.send(content: data, completion: .contentProcessed { error in
                    failed = error != nil
                    semaphore.signal()
                })
                semaphore.wait()
                if failed { return }
                position = chunkEnd + 1
            }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func send(_ connection: NWConnection, _ text: String, close: Bool) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in if close { connection.cancel() } })
    }
}

extension MediaStore {
    func entryById(_ id: String) -> Entry? {
        entryList().first { $0.id == id }
    }
}

/// Set once from the socket's queue, read from the streaming thread.
private final class ClosedFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
