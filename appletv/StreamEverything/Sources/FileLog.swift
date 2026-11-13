import Foundation

/// Copies everything the app writes to stderr (NSLog included) into
/// Library/Caches/app.log as well, so a failure on the TV can be read afterwards with
/// `devicectl device copy from` even when no console was attached at the time.
/// The file is truncated at launch and capped so it never grows without bound.
enum FileLog {
    private static let capBytes = 8 * 1024 * 1024
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let path = caches.appendingPathComponent("app.log").path
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: path) else { return }

        let original = dup(STDERR_FILENO)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let passthrough = FileHandle(fileDescriptor: original, closeOnDealloc: true)
        var written = 0
        Thread.detachNewThread {
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                passthrough.write(data)
                if written < capBytes {
                    file.write(data)
                    written += data.count
                }
            }
        }
    }
}
