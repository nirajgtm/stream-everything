import SwiftUI

// MARK: - Palette

/// The Android settings screen's colours, so both apps read as one product.
private enum SettingsPalette {
    static let accent = Color(red: 0x80 / 255, green: 0xCB / 255, blue: 0xC4 / 255)   // #80CBC4
    static let muted = Color(red: 0x9F / 255, green: 0xB3 / 255, blue: 0xC0 / 255)    // #9FB3C0
    static let error = Color(red: 1.0, green: 0x6B / 255, blue: 0x6B / 255)            // #FF6B6B
}

// MARK: - Account form model

/// The editable copy of the account plus everything "Test connection" and "Save" need to
/// know about it. Lives outside the view so the enclosing screen can ask `hasChanges`
/// when the user presses Menu, and so the first-run and Settings screens share one
/// implementation of the Android `SettingsActivity` rules.
@MainActor
final class AccountFormModel: ObservableObject {
    enum SaveOutcome {
        /// Saved; `changed` says whether the account differs from what was stored before.
        case saved(changed: Bool)
        /// The last test ran against exactly these values and failed; ask before saving.
        case needsConfirmation
        /// A field is blank; the status line already says so.
        case incomplete
    }

    let account: AccountStore
    /// No account at all yet: the form is a setup screen the user cannot back out of.
    let firstRun: Bool

    @Published var server: String { didSet { fieldEdited() } }
    @Published var username: String { didSet { fieldEdited() } }
    @Published var password: String { didSet { fieldEdited() } }
    @Published var showPassword = false

    @Published private(set) var testing = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var statusIsError = false

    /// What is on disk right now, so an edit can be told from an untouched field.
    private var stored: AccountStore.Account

    /// The exact values the last test ran against and how it went. Any later edit makes
    /// them stop matching, which retires the result.
    private var testedValues: AccountStore.Account?
    private var testedOk = false

    init(account: AccountStore) {
        self.account = account
        firstRun = !account.isConfigured
        stored = firstRun ? .empty : account.account
        server = stored.server
        username = stored.username
        password = stored.password
    }

    var currentValues: AccountStore.Account {
        AccountStore.Account(
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var hasChanges: Bool {
        let current = currentValues
        return AccountStore.normalizeServer(current.server) != AccountStore.normalizeServer(stored.server)
            || current.username != stored.username
            || current.password != stored.password
    }

    private var lastTestFailedForTheseValues: Bool {
        testedValues == currentValues && !testedOk
    }

    private func fieldEdited() {
        if let testedValues, testedValues != currentValues { clearStatus() }
    }

    func runConnectionTest() async {
        let values = currentValues
        testing = true
        statusIsError = false
        statusMessage = "Testing..."
        let result = await AccountStore.test(server: values.server, username: values.username, password: values.password)
        testing = false
        testedValues = values
        testedOk = result.ok
        showStatus(ok: result.ok, result.message)
    }

    func attemptSave() -> SaveOutcome {
        if !currentValues.isComplete {
            showStatus(ok: false, "Fill in server, username and password.")
            return .incomplete
        }
        if lastTestFailedForTheseValues { return .needsConfirmation }
        return .saved(changed: commitSave())
    }

    /// Write the account. A changed account also wipes the previous account's cached
    /// catalogs; an unchanged re-save leaves them alone because nothing is stale.
    @discardableResult
    func commitSave() -> Bool {
        let values = currentValues
        let changed = hasChanges
        if changed || firstRun {
            account.switchAccount(server: values.server, username: values.username, password: values.password)
        } else if account.isUserSupplied {
            account.save(server: values.server, username: values.username, password: values.password)
        }
        // Re-saving the built-in account unchanged stores nothing: the app keeps using
        // the baked-in credentials and the "built-in" wording stays truthful.
        stored = account.account
        server = stored.server
        username = stored.username
        password = stored.password
        showStatus(ok: true, "Account saved")
        return changed
    }

    private func showStatus(ok: Bool, _ message: String) {
        statusIsError = !ok
        statusMessage = message
    }

    private func clearStatus() {
        statusMessage = ""
        statusIsError = false
    }
}

// MARK: - Account form view

/// Server, username, password, Show password, Test connection, Save, optional Cancel and
/// the status line. The buttons report back through closures so the screen around it
/// decides what dismissing means (pop Settings, or move on from first-run setup).
struct AccountForm: View {
    @ObservedObject var form: AccountFormModel
    /// Save finished; `changed` is true when the stored account differs from before.
    var onSaved: (_ changed: Bool) -> Void
    /// Only shown when not first run.
    var onCancel: () -> Void

    @State private var confirmingSaveAnyway = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            labelled("Server URL") {
                TextField("http://your-server.com:8080", text: $form.server)
                    .keyboardType(.URL)
                    .textContentType(.URL)
            }
            labelled("Username") {
                TextField("username", text: $form.username)
                    .textContentType(.username)
            }
            labelled("Password") {
                // Two controls rather than one with a flag: SecureField has no way to reveal
                // its text, and tvOS users mistype often enough that seeing it matters.
                if form.showPassword {
                    TextField("password", text: $form.password)
                } else {
                    SecureField("password", text: $form.password)
                }
            }
            Toggle("Show password", isOn: $form.showPassword)
                .frame(maxWidth: 620)

            HStack(spacing: 18) {
                Button(form.testing ? "Testing..." : "Test connection") {
                    Task { await form.runConnectionTest() }
                }
                .disabled(form.testing)
                Button("Save") { save() }
                if !form.firstRun {
                    Button("Cancel") { onCancel() }
                }
            }
            .padding(.top, 8)

            if !form.statusMessage.isEmpty {
                Text(form.statusMessage)
                    .font(.body)
                    .foregroundStyle(form.statusIsError ? SettingsPalette.error : SettingsPalette.accent)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .alert("Save anyway?", isPresented: $confirmingSaveAnyway) {
            Button("Save") { onSaved(form.commitSave()) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This account failed the connection test. Save anyway?")
        }
    }

    /// Exposed so the screen's "Save changes?" prompt can reuse the same path.
    func save() {
        switch form.attemptSave() {
        case .incomplete: break
        case .needsConfirmation: confirmingSaveAnyway = true
        case .saved(let changed): onSaved(changed)
        }
    }

    /// A caption above its field, as one block in the column.
    private func labelled<Field: View>(_ caption: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.callout).foregroundStyle(SettingsPalette.muted)
            field().frame(maxWidth: 620)
        }
    }
}

// MARK: - Settings screen

/// The tvOS settings screen: Xtream account, playback, content filter, connection status
/// and app version. Push it from Home; it pops itself when the account is saved.
struct SettingsView: View {
    @ObservedObject var account: AccountStore
    @ObservedObject var settings: Settings
    /// A different account was saved and its cache wiped; drop the loaded catalogs and reload.
    var onAccountChanged: () -> Void = {}

    @StateObject private var form: AccountFormModel
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingSaveOnExit = false
    @State private var filterNotice = ""
    @State private var connection: AccountStore.TestResult?
    @State private var checkingConnection = false

    init(account: AccountStore, settings: Settings, onAccountChanged: @escaping () -> Void = {}) {
        self.account = account
        self.settings = settings
        self.onAccountChanged = onAccountChanged
        _form = StateObject(wrappedValue: AccountFormModel(account: account))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Settings").font(.system(size: 44, weight: .bold))

                section("Xtream account") {
                    AccountForm(form: form, onSaved: finishSave, onCancel: { dismiss() })
                    if account.isUserSupplied && account.hasBuiltInAccount {
                        Button("Use the built-in account") {
                            account.revertToBuiltIn()
                            finishSave(true)
                        }
                        .padding(.top, 4)
                    }
                }

                section("Playback") {
                    Toggle("Live TV controls", isOn: $settings.liveControls)
                        .frame(maxWidth: 620)
                    footnote("Show the pause, forward and backward controls while watching Live TV.")
                }

                section("Content") {
                    HStack(spacing: 14) {
                        Text("Trending from").frame(width: 260, alignment: .leading)
                        ForEach(Settings.trendingRegions, id: \.code) { region in
                            let selected = region.code.isEmpty ? settings.trendingRegionCodes.isEmpty
                                                               : settings.trendingRegionCodes.contains(region.code)
                            Button(region.label) { settings.toggleTrendingRegion(region.code) }
                                .buttonStyle(ChipButtonStyle(selected: selected))
                        }
                    }
                    footnote("Pick one or more countries; their trending titles are mixed into the rail on home. Global uses TMDB's worldwide feed.")
                    if !filterNotice.isEmpty {
                        Text(filterNotice).font(.body).foregroundStyle(SettingsPalette.accent)
                    }
                }

                section("Connection") { connectionRows }

                section("About") {
                    row("Version", appVersion)
                    row("Account", account.isUserSupplied ? "Saved on this device" : "Built into this app")
                    row("Server", account.account.server)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .onExitCommand(perform: handleExit)
        .task { await refreshConnection() }
        .alert("Save changes?", isPresented: $confirmingSaveOnExit) {
            Button("Save") {
                switch form.attemptSave() {
                case .saved(let changed): finishSave(changed)
                // Blank field or failed test: stay on the screen so the form can explain.
                case .incomplete, .needsConfirmation: break
                }
            }
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account details have changed.")
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var connectionRows: some View {
        if checkingConnection {
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking...").foregroundStyle(SettingsPalette.muted)
            }
        } else if let connection {
            row("Status", connection.ok ? (connection.status.isEmpty ? "Active" : connection.status) : connection.message,
                tint: connection.ok ? SettingsPalette.accent : SettingsPalette.error)
            if connection.ok {
                row("Connections", connectionsText(connection))
                row("Expires", connection.expiryText ?? "No expiry")
            }
        } else if !account.isConfigured {
            footnote("No account configured.")
        }
        Button("Refresh") { Task { await refreshConnection() } }
            .disabled(checkingConnection || !account.isConfigured)
            .padding(.top, 4)
    }

    private func connectionsText(_ result: AccountStore.TestResult) -> String {
        let active = result.activeConnections.isEmpty ? "0" : result.activeConnections
        let max = result.maxConnections.isEmpty ? "?" : result.maxConnections
        return "\(active) of \(max) in use"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.callout.weight(.semibold))
                .tracking(2)
                .foregroundStyle(SettingsPalette.accent)
            content()
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label).foregroundStyle(SettingsPalette.muted).frame(width: 200, alignment: .leading)
            Text(value).foregroundStyle(tint).lineLimit(2)
        }
        .font(.body)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(SettingsPalette.muted)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: Actions

    private func finishSave(_ changed: Bool) {
        if changed { onAccountChanged() }
        dismiss()
    }

    /// Menu button: leave at once when nothing changed, otherwise ask, like Android's Back.
    private func handleExit() {
        if form.hasChanges {
            confirmingSaveOnExit = true
        } else {
            dismiss()
        }
    }

    private func refreshConnection() async {
        guard account.isConfigured else { connection = nil; return }
        checkingConnection = true
        connection = await account.testCurrentAccount()
        checkingConnection = false
    }

    /// A toast stand-in: tvOS has none, so show the line for a few seconds then clear it.
    private func flash(_ message: String) {
        filterNotice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if filterNotice == message { filterNotice = "" }
        }
    }
}

// MARK: - First run

/// Shown instead of Home when no account is configured (no saved account and no built-in
/// one). There is no Cancel and Menu is left to the system, which suspends the app, the
/// same outcome as Android's Back finishing the activity.
struct AccountSetupView: View {
    @ObservedObject var account: AccountStore
    /// An account was saved; load the catalogs and show Home.
    var onConfigured: () -> Void

    @StateObject private var form: AccountFormModel

    init(account: AccountStore, onConfigured: @escaping () -> Void) {
        self.account = account
        self.onConfigured = onConfigured
        _form = StateObject(wrappedValue: AccountFormModel(account: account))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Set up your Xtream account").font(.system(size: 44, weight: .bold))
                Text("Enter the server address, username and password your IPTV provider gave you. Test the connection, then save to start watching.")
                    .font(.body)
                    .foregroundStyle(SettingsPalette.muted)
                    .frame(maxWidth: 900, alignment: .leading)
                AccountForm(form: form, onSaved: { _ in onConfigured() }, onCancel: {})
                    .padding(.top, 12)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - Adult filter unlock

/// Asks for the unlock phrase before the adult filter may be turned off. Wrong answers
/// just say so; the filter stays on until the phrase matches.
struct AdultFilterUnlockView: View {
    @ObservedObject var settings: Settings
    var onUnlocked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var wrongPhrase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Turn off the adult filter").font(.system(size: 40, weight: .bold))
            Text("Type the unlock phrase to show adult titles everywhere in the app.")
                .font(.body)
                .foregroundStyle(SettingsPalette.muted)
            TextField("Unlock phrase", text: $phrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 620)
                .onChange(of: phrase) { _, _ in wrongPhrase = false }
                .onSubmit(unlock)
            HStack(spacing: 18) {
                Button("Unlock", action: unlock)
                Button("Cancel") { dismiss() }
            }
            if wrongPhrase {
                Text("That is not the phrase.").foregroundStyle(SettingsPalette.error)
            }
        }
        .padding(60)
    }

    private func unlock() {
        if settings.unlockAdultFilter(with: phrase) {
            onUnlocked()
            dismiss()
        } else {
            wrongPhrase = true
        }
    }
}
