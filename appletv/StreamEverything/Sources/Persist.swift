import Foundation

/// Small app state (resume history, favorites, channel memory, source choices,
/// platform affinity) goes through here. On tvOS, UserDefaults is the only storage
/// the system promises to keep; files under Application Support or Caches can be
/// purged, and were lost on reinstall. UserDefaults is the record of truth; the file
/// is written too as a fallback and for anything saved by older builds.
enum Persist {
    static func save(_ data: Data, key: String, file: URL?) {
        UserDefaults.standard.set(data, forKey: "store." + key)
        if let file { try? data.write(to: file, options: .atomic) }
    }

    static func load(key: String, file: URL?) -> Data? {
        if let data = UserDefaults.standard.data(forKey: "store." + key), !data.isEmpty { return data }
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        // Adopt an older file-only save so it is never lost again.
        UserDefaults.standard.set(data, forKey: "store." + key)
        return data
    }
}
