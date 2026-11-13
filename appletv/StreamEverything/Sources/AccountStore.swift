import Foundation

/// The Xtream account the app talks to.
///
/// Stored on the device so it can be changed from Settings, but it falls back to the
/// values baked in at build time (Credentials.swift): a build made for one person keeps
/// working untouched, and only an explicit save in Settings overrides it.
///
/// Port of the Android `XtreamCredentials`, with the cache wipe from
/// `XtreamClient.switchAccount` folded in because the catalog files are the only
/// account-specific state the tvOS client keeps on disk.
@MainActor
final class AccountStore: ObservableObject {

    /// Server, username and password as one value so edits can be compared as a whole.
    struct Account: Equatable {
        var server: String
        var username: String
        var password: String

        /// True when every field has something in it; the only requirement for "configured".
        var isComplete: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty }

        static let empty = Account(server: "", username: "", password: "")
    }

    /// What the server said when asked to authenticate an account.
    ///
    /// `message` is the one line a user can act on (why it failed, or what the account
    /// allows). The other fields are the raw facts so the Connection section can lay
    /// them out on separate rows.
    struct TestResult {
        let ok: Bool
        let message: String
        var status = ""
        var activeConnections = ""
        var maxConnections = ""
        var expiryDate: Date? = nil

        /// "12 Mar 2027", or nil when the provider reports no expiry.
        var expiryText: String? { expiryDate.map { AccountStore.expiryFormatter.string(from: $0) } }

        static func failure(_ message: String) -> TestResult { TestResult(ok: false, message: message) }
    }

    // Namespaced like the Android SharedPreferences file so they cannot collide with
    // the app-wide Settings keys ("liveControls", "adultFilter") in the same defaults.
    private static let serverKey = "xtream_credentials.server"
    private static let usernameKey = "xtream_credentials.username"
    private static let passwordKey = "xtream_credentials.password"

    /// The account baked into this build; empty when the build was made without one.
    static let builtIn = Account(server: Credentials.server, username: Credentials.user, password: Credentials.pass)

    /// Where XtreamClient keeps its catalog JSON files. Must match XtreamClient.init.
    nonisolated static var catalogCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalog", isDirectory: true)
    }

    nonisolated static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private let defaults: UserDefaults

    /// The account in effect right now: each field is the saved value when one is
    /// present and non-blank, otherwise the built-in one (same per-field fallback as Android).
    @Published private(set) var account: Account

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        account = Self.readAccount(from: defaults)
    }

    /// True once there is a usable account, whether saved here or built in.
    var isConfigured: Bool { account.isComplete }

    /// True when the user has saved their own account (not the built-in one).
    var isUserSupplied: Bool { defaults.object(forKey: Self.serverKey) != nil }

    /// True when forgetting the saved account would still leave a working one.
    var hasBuiltInAccount: Bool { Self.builtIn.isComplete }

    /// A client for the current account. AppState rebuilds its client from this after a switch.
    func makeClient() -> XtreamClient {
        XtreamClient(server: account.server, user: account.username, pass: account.password)
    }

    /// Persist a new account without touching any cache. Prefer `switchAccount` when the
    /// account actually changed, so the old subscription's catalog does not linger.
    func save(server: String, username: String, password: String) {
        defaults.set(Self.normalizeServer(server), forKey: Self.serverKey)
        defaults.set(username.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.usernameKey)
        defaults.set(password.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.passwordKey)
        account = Self.readAccount(from: defaults)
    }

    /// Adopt a different account and throw away everything cached for the previous one.
    /// The catalogs are account-specific, so keeping them would show another
    /// subscription's content until the daily refresh. The caller must rebuild its
    /// XtreamClient (`makeClient()`) and reload.
    func switchAccount(server: String, username: String, password: String) {
        save(server: server, username: username, password: password)
        Self.clearCatalogCache()
    }

    /// Forget the saved account and fall back to the built-in one.
    func clear() {
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.passwordKey)
        account = Self.readAccount(from: defaults)
    }

    /// `clear()` plus the cache wipe, because going back to the built-in account is a
    /// switch like any other.
    func revertToBuiltIn() {
        clear()
        Self.clearCatalogCache()
    }

    /// Delete every cached catalog file so the next `load()` downloads fresh lists.
    /// The directory itself stays; XtreamClient recreates it anyway.
    nonisolated static func clearCatalogCache() {
        let dir = catalogCacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Accepts "host.com", "host.com:8080" or a full URL; always returns a URL with no
    /// trailing slash (XtreamClient appends paths to it).
    nonisolated static func normalizeServer(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        return "http://\(trimmed)"
    }

    /// Ask the server to authenticate the account. Reports why it failed so the user can
    /// fix it, rather than a bare "failed". Safe to call from any context: it awaits the
    /// network and never touches the main actor.
    nonisolated static func test(server: String, username: String, password: String) async -> TestResult {
        let base = normalizeServer(server)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || user.isEmpty || pass.isEmpty {
            return .failure("Fill in server, username and password.")
        }
        guard let url = URL(string: "\(base)/player_api.php?username=\(user)&password=\(pass)") else {
            return .failure("That server address is not a valid URL.")
        }

        // Ephemeral so a failed test leaves no cookies or cached reply behind, and short
        // timeouts so a wrong address fails while the user is still looking at the screen.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure("Server replied HTTP \(http.statusCode).")
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure("Not an Xtream server (unexpected reply).")
            }
            guard let info = root["user_info"] as? [String: Any] else {
                return .failure("Server did not return an account.")
            }

            let auth = Lossy.string(info["auth"])
            let status = Lossy.string(info["status"])
            let blocked = status.caseInsensitiveCompare("Banned") == .orderedSame
                || status.caseInsensitiveCompare("Disabled") == .orderedSame
            if auth != "1" || blocked {
                return .failure("Rejected: wrong username/password" + (status.isEmpty ? "." : " (status \(status))."))
            }

            let expiry = Double(Lossy.string(info["exp_date"])).map { Date(timeIntervalSince1970: $0) }
            let active = Lossy.string(info["active_cons"])
            let max = Lossy.string(info["max_connections"])

            var message = "Connected"
            if !status.isEmpty { message += " · \(status)" }
            if let expiry { message += " · expires \(expiryFormatter.string(from: expiry))" }
            if !max.isEmpty { message += " · \(max) connections" }

            return TestResult(ok: true, message: message, status: status,
                              activeConnections: active, maxConnections: max, expiryDate: expiry)
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .unsupportedURL, .badURL:
                return .failure("Can't reach that server, check the address.")
            case .timedOut:
                return .failure("Timed out reaching the server.")
            default:
                return .failure("Couldn't connect: \(error.localizedDescription)")
            }
        } catch {
            return .failure("Couldn't connect: \(error.localizedDescription)")
        }
    }

    /// Check the account currently in effect (saved or built in).
    func testCurrentAccount() async -> TestResult {
        await Self.test(server: account.server, username: account.username, password: account.password)
    }

    // MARK: Private

    private static func readAccount(from defaults: UserDefaults) -> Account {
        func stored(_ key: String, or fallback: String) -> String {
            let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        return Account(
            server: stored(serverKey, or: builtIn.server),
            username: stored(usernameKey, or: builtIn.username),
            password: stored(passwordKey, or: builtIn.password))
    }
}
