import SwiftUI

@main
struct StreamEverythingApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() { FileLog.install() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
        // A download left open while the app is off screen would hold the account's one
        // connection for every other device; stop it the moment we leave.
        .onChange(of: scenePhase) { _, phase in
            state.mediaDownloader.setSuspended(phase != .active || state.isPlayingLive)
            if phase == .active { state.mediaServer.ensureListening() }
        }
    }
}

/// First run with no account asks for one; otherwise the catalogs load (the home
/// skeleton and snapshot paint as soon as the series list is in) and Home shows.
struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if !app.account.isConfigured {
                AccountSetupView(account: app.account) {
                    // Coming back from first-run setup: nothing was loaded yet, so start now.
                    Task { await app.load() }
                }
            } else if app.ready {
                NavigationStack(path: $app.path) {
                    HomeView().appRouteDestinations()
                }
            } else {
                VStack(spacing: 24) {
                    ProgressView()
                    Text(app.status).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
        .task { await app.load() }
    }
}

/// Poster card used on every rail and grid.
struct PosterCard: View {
    let title: String
    let imageUrl: String
    var progress: Double = 0
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color(white: 0.16)
                CachedImage(url: URL(string: imageUrl)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
                if progress > 0.01 && progress < 0.99 {
                    GeometryReader { geo in
                        Rectangle().fill(Color(red: 0.5, green: 0.8, blue: 0.77))
                            .frame(width: geo.size.width * progress, height: 6)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: wide ? 360 : 220, height: wide ? 202 : 320)
            .clipped()
            Text(title).font(.caption).lineLimit(2).frame(width: wide ? 360 : 220, alignment: .leading)
        }
    }
}
