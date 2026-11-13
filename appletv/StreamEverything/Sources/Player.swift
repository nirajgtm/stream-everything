import SwiftUI
import UIKit
import TVVLCKit

/// One episode of a series playlist handed to the player, so previous/next, the
/// "Up next" prompt and the episode strip work without going back to the series page.
struct PlaylistEpisode {
    let url: URL
    /// Overlay title, e.g. "Show Name · S1 E4".
    let title: String
    /// The episode's own name, for cards and the up-next prompt.
    let episodeTitle: String
    let season: Int
    let number: Int
    let plot: String
    /// Still or poster for cards; the series poster is a fine fallback.
    let image: String
    /// Resume mark for this episode (key, series ids). `positionMs` is used to resume
    /// when the player switches to it, and refreshed as it plays.
    let mark: ResumeStore.Mark
}

/// Everything the player needs to start and to record where playback stops.
struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let isLive: Bool
    let startMs: Int
    /// Resume mark to keep updated; nil for live.
    let mark: ResumeStore.Mark?
    /// Poster for the info panel and the up-next card.
    let poster: String
    /// Plot for the info panel (Down arrow / paused).
    let plot: String
    /// Meta line under the title in the info panel, e.g. "2021  ·  Drama".
    let meta: String
    /// Whole-series playlist; empty for movies, live and a lone episode. When present it
    /// takes over from `url`/`mark`: playback starts at `playlist[startIndex]`.
    let playlist: [PlaylistEpisode]
    let startIndex: Int
    /// Called when the player closes, with the item that was actually on screen.
    /// `PlaybackReturnStore.shared.last` carries the same value for views that prefer state.
    let onReturn: ((PlaybackReturn) -> Void)?
    /// For live: the list the channel was picked from, so Up/Down zap through it.
    var zapList: [Entry] = []
    var zapIndex: Int = 0
    /// ISO 639-1 code of the title's original language (from TMDB), "" when unknown.
    var originalLanguage: String = ""

    init(url: URL, title: String, isLive: Bool, startMs: Int, mark: ResumeStore.Mark?,
         poster: String = "", plot: String = "", meta: String = "",
         playlist: [PlaylistEpisode] = [], startIndex: Int = 0,
         onReturn: ((PlaybackReturn) -> Void)? = nil) {
        self.url = url
        self.title = title
        self.isLive = isLive
        self.startMs = startMs
        self.mark = mark
        self.poster = poster
        self.plot = plot
        self.meta = meta
        self.playlist = playlist
        self.startIndex = playlist.isEmpty ? 0 : max(0, min(startIndex, playlist.count - 1))
        self.onReturn = onReturn
    }
}

struct PlayerScreen: View {
    let request: PlayRequest
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlayerContainer(request: request, resume: app.resume, client: app.client, app: app, onExit: { dismiss() })
            .ignoresSafeArea()
            .onAppear { app.isPlaying = true; app.isPlayingLive = request.isLive }
            .onDisappear { app.isPlaying = false; app.isPlayingLive = false }
    }
}

private struct PlayerContainer: UIViewControllerRepresentable {
    let request: PlayRequest
    let resume: ResumeStore
    let client: XtreamClient
    let app: AppState
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(request: request, resume: resume, client: client, app: app, onExit: onExit)
    }
    func updateUIViewController(_ controller: PlayerViewController, context: Context) {}
}

/// VLC-backed player with everything a TV remote needs: play/pause, accelerating seek,
/// episode playlists with an "Up next" prompt, subtitle/audio picking, live recovery
/// that never gives up, and progress saving into `ResumeStore`.
///
/// Remote map: Play/Pause or Select toggles pause (or acts on an open panel), Left/Right
/// seek -10s/+30s (hold or tap repeatedly to accelerate), Up opens the episode strip
/// then the track menu, Down opens the info panel, Menu closes a panel or exits.
final class PlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
    private let request: PlayRequest
    private let resume: ResumeStore
    private let client: XtreamClient
    private let onExit: () -> Void
    private let player = VLCMediaPlayer()
    private let videoView = UIView()

    // Overlays
    private let controls = ControlsOverlay()
    private let infoPanel = InfoPanel()
    private let episodeStrip = EpisodeStripView()
    private let trackMenu = TrackMenuView()
    private let upNextCard = UpNextCard()
    private let nextHint = PillLabel()
    private let seekIndicator = PillLabel()
    private let notice = PillLabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let zapListOverlay = ZapListOverlay()
    private var zapListTimer: Timer?

    private enum TopPanel { case none, episodes, tracks, info }
    private var topPanel: TopPanel = .none

    // Timers
    private var hideControlsTimer: Timer?
    private var saveTimer: Timer?
    private var tickTimer: Timer?
    private var watchdogTimer: Timer?
    private var holdSeekTimer: Timer?
    private var upNextTimer: Timer?
    private var seekIndicatorTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?

    // What is playing
    private var currentIndex: Int
    private var currentMark: ResumeStore.Mark?
    private var currentTitle: String
    private var currentPlot: String
    /// Live: which channel of the zap list is on; its URL replaces request.url.
    private var zapIndex: Int
    private var liveUrl: URL
    private var pendingStartMs = 0
    private var openedAt = Date()
    private var hasPlayedSinceOpen = false
    private var firstFrameLogged = false
    private var tracksApplied = false
    private var lastKnownPositionMs = 0
    private var lastKnownDurationMs = 0
    /// True while the viewer wants playback to continue; the watchdog and recovery
    /// only act when this is set, so an intentional pause never looks like a stall.
    private var wantsPlaying = true
    private var hasExited = false

    // Live recovery
    private var liveRetries = 0
    private var liveStalledSince: Date?
    private var lastLivePositionMs = -1

    // Connection-limit recovery
    private var connectionLimitSeenAt: Date?
    private var pausedInBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var connectionRetries = 0
    private var connectionCounts = ""

    // Episode flow
    private var upNextPending = false
    private var upNextSecondsLeft = 0
    private var nextHintDismissed = false
    private var nextUpRecorded = false
    private var finishedRecorded = false

    // Seek acceleration
    private var seekStreak = 0
    private var lastSeekPressAt = Date.distantPast
    private var holdDeltaMs = 0

    private var isPlaylist: Bool { request.playlist.count > 1 }
    private var hasNextEpisode: Bool { isPlaylist && currentIndex + 1 < request.playlist.count }
    private var hasPreviousEpisode: Bool { isPlaylist && currentIndex > 0 }
    /// Live hides the time bar unless the viewer turned it on in settings.
    private var controlsAllowed: Bool { !request.isLive || PlayerPreferences.liveControls }

    private let app: AppState

    init(request: PlayRequest, resume: ResumeStore, client: XtreamClient, app: AppState, onExit: @escaping () -> Void) {
        self.app = app
        self.request = request
        self.resume = resume
        self.client = client
        self.onExit = onExit
        self.currentIndex = request.startIndex
        self.zapIndex = request.zapIndex
        self.liveUrl = request.url
        if !request.playlist.isEmpty {
            let episode = request.playlist[request.startIndex]
            self.currentMark = episode.mark
            self.currentTitle = episode.title
            self.currentPlot = episode.plot.isEmpty ? request.plot : episode.plot
        } else {
            self.currentMark = request.mark
            self.currentTitle = request.title
            self.currentPlot = request.plot
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildViews()

        VlcLogWatcher.shared.install()
        VlcLogWatcher.shared.onConnectionLimit = { [weak self] in self?.connectionLimitSeenAt = Date() }

        player.drawable = videoView
        player.delegate = self

        // On the Siri Remote the Menu press goes to gesture recognizers before the
        // responder chain, and SwiftUI's presenter has one that dismisses the screen.
        // Our own recognizer wins (the others must wait for it to fail), so Menu
        // reaches the same handler as every other key.
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.delegate = self
        view.addGestureRecognizer(menuTap)

        // Off screen, the stream must close: a frozen app's open socket keeps holding
        // the account's single connection. Coming back reopens where it was.
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !hasExited else { return }
            saveProgress()
            cancelUpNext()
            hasPlayedSinceOpen = false   // our own stop: not the episode ending
            player.stop()
            pausedInBackground = true
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !hasExited, pausedInBackground else { return }
            pausedInBackground = false
            reopenCurrent(at: request.isLive ? 0 : lastKnownPositionMs)
        })

        if !request.playlist.isEmpty {
            openEpisode(at: request.startIndex, startMs: request.startMs)
        } else {
            openMedia(url: request.url, startMs: request.startMs)
            publishReturn()
        }
        if controlsAllowed { showControls() }

        // First checkpoint early so leaving quickly still records progress, then every
        // minute as a safety net; pauses and transport presses save on their own.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.saveProgress()
            self?.saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.saveProgress()
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        startLiveWatchdog()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        tearDown()
    }

    /// Stops everything exactly once; called from Menu and from the view going away.
    private func tearDown() {
        guard !hasExited else { return }
        hasExited = true
        [hideControlsTimer, saveTimer, tickTimer, watchdogTimer, holdSeekTimer, upNextTimer, seekIndicatorTimer, zapListTimer, commitSeekTimer, zapCommitTimer]
            .forEach { $0?.invalidate() }
        retryWork?.cancel()
        exitWork?.cancel()
        VlcLogWatcher.shared.onConnectionLimit = nil
        saveProgress()
        publishReturn()
        player.stop()
    }

    private func exit() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
        tearDown()
        onExit()
    }

    private func buildViews() {
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        controls.configure(title: currentTitle, subtitle: request.isLive ? "" : request.meta, isLive: request.isLive)
        // Order is the Left/Right walking order: rewind, play, forward in the centre,
        // then the option pills along the bottom.
        refreshControlList()
        controls.alpha = 0
        infoPanel.alpha = 0
        infoPanel.configure(title: currentTitle, meta: infoMeta(), plot: currentPlot, poster: request.poster)
        episodeStrip.alpha = 0
        trackMenu.alpha = 0
        upNextCard.isHidden = true
        nextHint.isHidden = true
        nextHint.text = "Next episode   ▶   Select"
        nextHint.fillColor = PlayerStyle.accent.withAlphaComponent(0.92)
        nextHint.textColor = PlayerStyle.panel
        seekIndicator.isHidden = true
        seekIndicator.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        notice.isHidden = true
        notice.font = .systemFont(ofSize: 24, weight: .medium)
        spinner.color = .white
        spinner.startAnimating()

        zapListOverlay.isHidden = true
        for overlay in [controls, infoPanel, episodeStrip, trackMenu, upNextCard, nextHint, seekIndicator, notice, spinner, zapListOverlay] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
        }
        let m = PlayerStyle.sideMargin
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            infoPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoPanel.topAnchor.constraint(equalTo: view.topAnchor),
            infoPanel.heightAnchor.constraint(equalToConstant: 560),

            episodeStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            episodeStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            episodeStrip.topAnchor.constraint(equalTo: view.topAnchor),
            episodeStrip.heightAnchor.constraint(equalToConstant: 480),

            trackMenu.topAnchor.constraint(equalTo: view.topAnchor, constant: 70),
            trackMenu.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),

            upNextCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            upNextCard.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -110),

            nextHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            nextHint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -300),

            seekIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            seekIndicator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -300),

            notice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            notice.topAnchor.constraint(equalTo: view.topAnchor, constant: 70),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),

            // Under the transport buttons, never on them.
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 140),

            zapListOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            zapListOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            zapListOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            zapListOverlay.widthAnchor.constraint(equalToConstant: 620),
        ])
    }

    /// Live: the channel list down the left with the current one lit, while zapping
    /// and for a moment after; it goes away once the viewer settles on a channel.
    private func showZapList(hideAfter: TimeInterval = 2.5) {
        guard request.isLive, !request.zapList.isEmpty else { return }
        zapListOverlay.configure(names: request.zapList.map(\.displayTitle), current: zapIndex)
        zapListOverlay.layer.removeAllAnimations()
        zapListOverlay.alpha = 1
        zapListOverlay.isHidden = false
        zapListTimer?.invalidate()
        zapListTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in self?.hideZapList() }
    }

    private func hideZapList() {
        zapListTimer?.invalidate()
        UIView.animate(withDuration: 0.25, animations: { self.zapListOverlay.alpha = 0 }) { finished in
            guard finished else { return }   // shown again mid-fade: leave it up
            self.zapListOverlay.isHidden = true
            self.zapListOverlay.alpha = 1
        }
    }

    // MARK: Opening media

    /// Opens `url` from scratch. Used for the first item, every episode switch, and every
    /// live or connection-limit recovery; VLC has no "re-prepare", so re-open is the move.
    private func openMedia(url: URL, startMs: Int) {
        // VOD goes through the local store so the player reads from disk and the
        // downloader is the only thing on the network.
        // Live streams straight from the provider, so the downloader must let go of the
        // connection before VLC connects; VOD reads through the downloader, so it runs.
        app.mediaDownloader.setSuspended(request.isLive)
        let url = request.isLive ? url : app.playableURL(for: url)
        retryWork?.cancel()
        pendingStartMs = startMs
        hasPlayedSinceOpen = false
        firstFrameLogged = false
        tracksApplied = false
        openedAt = Date()
        wantsPlaying = true
        spinner.startAnimating()

        let media = VLCMedia(url: url)
        // Live rides on a few seconds of network cache; VOD comes from the local
        // server at disk speed, so a small cache keeps seeks instant.
        media.addOption(request.isLive ? ":network-caching=3000" : ":network-caching=600")
        media.addOption(":http-user-agent=VLC/3.0.20 LibVLC/3.0.20")
        // Open straight at the resume point instead of decoding from the start and
        // seeking afterwards: one connection, one buffer fill.
        if startMs > 0, !request.isLive { media.addOption(":start-time=\(Double(startMs) / 1000)") }
        player.media = media
        player.play()
    }

    /// Switches the playlist to `index`. The episode's own resume mark decides where it
    /// starts (with the 3s pre-roll) unless the caller passes an explicit `startMs`.
    private func openEpisode(at index: Int, startMs explicitStartMs: Int? = nil) {
        guard request.playlist.indices.contains(index) else { return }
        let episode = request.playlist[index]
        cancelUpNext()
        hideNextHint()
        nextHintDismissed = false
        nextUpRecorded = false
        finishedRecorded = false
        currentIndex = index
        currentTitle = episode.title
        currentPlot = episode.plot.isEmpty ? request.plot : episode.plot
        refreshControlList()

        // Remember the mark first so later `update` calls have something to update, and so
        // Continue Watching shows this episode as the series' latest right away.
        var mark = episode.mark
        if let saved = resume.mark(for: mark.key) {
            mark.positionMs = saved.positionMs
            if saved.durationMs > 0 { mark.durationMs = saved.durationMs }
        }
        currentMark = mark
        resume.remember(mark)

        let startMs: Int
        if let explicitStartMs {
            startMs = explicitStartMs
        } else if mark.positionMs > 5_000, !mark.finished {
            startMs = max(0, mark.positionMs - 3_000)
        } else {
            startMs = 0
        }

        controls.configure(title: currentTitle, subtitle: request.meta, isLive: false)
        infoPanel.configure(title: currentTitle, meta: infoMeta(), plot: currentPlot,
                            poster: request.poster.isEmpty ? episode.image : request.poster)
        openMedia(url: episode.url, startMs: startMs)
        publishReturn()
    }

    /// The provider URL of what is playing (the store is keyed by it).
    private var currentRemoteURL: URL {
        request.playlist.indices.contains(currentIndex) ? request.playlist[currentIndex].url : request.url
    }

    private func infoMeta() -> String {
        if request.isLive { return player.state == .paused ? "Paused" : "Live" }
        guard !request.playlist.isEmpty, request.playlist.indices.contains(currentIndex) else { return request.meta }
        let episode = request.playlist[currentIndex]
        var parts = ["Season \(episode.season)  ·  Episode \(episode.number)"]
        if !episode.episodeTitle.isEmpty { parts.append(episode.episodeTitle) }
        if lastKnownDurationMs > 0 { parts.append("\(lastKnownDurationMs / 60_000) min") }
        return parts.joined(separator: "   •   ")
    }

    // MARK: Remote

    /// Menu arrives through the gesture recognizer on the Siri Remote and through
    /// pressesBegan in the simulator (sometimes both): handle one press once.
    private var lastMenuAt = Date.distantPast

    private func handleMenu() {
        guard !hasExited, Date().timeIntervalSince(lastMenuAt) > 0.3 else { return }
        lastMenuAt = Date()
        handleRemotePress(.menu, presses: [], event: nil)
    }

    @objc private func menuPressed() { handleMenu() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let type = remotePressType(press) else {
            return super.pressesBegan(presses, with: event)
        }
        handleRemotePress(type, presses: presses, event: event)
    }

    /// The Siri Remote sends the standard press types; the simulator (and a paired
    /// keyboard) sends HID key codes instead, sometimes alongside the remote type for
    /// the same key. Map the keys the player cares about and drop the duplicate.
    private var lastMappedPress: (type: Int, at: TimeInterval) = (-1, 0)
    private func remotePressType(_ press: UIPress) -> UIPress.PressType? {
        let mapped: UIPress.PressType?
        switch press.type.rawValue {
        case 2082: mapped = .upArrow
        case 2081: mapped = .downArrow
        case 2080: mapped = .leftArrow
        case 2079: mapped = .rightArrow
        case 2040, 2088: mapped = .select        // Return, keypad Enter
        case 2041: mapped = .menu                // Escape
        case 2044: mapped = .playPause           // Space
        case UIPress.PressType.menu.rawValue: handleMenu(); return nil   // once, with the gesture
        default: mapped = press.type
        }
        guard let mapped else { return nil }
        let now = Date().timeIntervalSince1970
        if lastMappedPress.type == mapped.rawValue, now - lastMappedPress.at < 0.12 { return nil }
        lastMappedPress = (mapped.rawValue, now)
        return mapped
    }

    private func handleRemotePress(_ type: UIPress.PressType, presses: Set<UIPress>, event: UIPressesEvent?) {
        let press = PressStandIn(type: type)

        // The up-next prompt owns Select and Menu while it shows.
        if upNextPending {
            switch press.type {
            case .select, .playPause: playNextEpisode(); return
            case .menu: cancelUpNext(); showControls(); return
            default: break
            }
        }
        // The last-two-minutes hint: Select takes it, any direction dismisses it.
        if !nextHint.isHidden {
            switch press.type {
            case .select: playNextEpisode(); return
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                hideNextHint(); nextHintDismissed = true; showControls(); return
            case .menu:
                hideNextHint(); nextHintDismissed = true; return   // first Menu only clears the hint
            default: break
            }
        }
        if topPanel != .none {
            handlePanelPress(press.type)
            return
        }

        // Controls hidden: every key first brings them up with Play/Pause lit. Only the
        // dedicated play/pause key also acts. (Live without the bar keeps its own
        // behaviour: Select shows the channel info, Up/Down zap.)
        if !barIsUp && controlsAllowed && press.type != .playPause && press.type != .menu {
            controls.setCursor(to: .playPause)
            showControls()
            return
        }

        switch press.type {
        case .playPause:
            // The dedicated key always toggles and shows the controls with Play/Pause lit.
            togglePause()
            controls.setCursor(to: .playPause)
            showControls()
        case .select:
            // With the bar hidden, Select just brings it up (Play/Pause highlighted);
            // with it showing, Select presses the highlighted button.
            if !barIsUp || !controlsAllowed {
                if request.isLive && !PlayerPreferences.liveControls { showZapList() }
                else { controls.setCursor(to: .playPause); showControls() }
            } else if controls.barFocused {
                togglePause()
                showControls()
            } else {
                activateHighlightedControl()
                showControls()
            }
        case .leftArrow, .rightArrow:
            if controls.barFocused {
                // On the time bar: a minute per press, and a held press keeps sliding.
                beginSeek(deltaMs: type == .leftArrow ? -60_000 : 60_000)
            } else {
                controls.moveCursor(by: type == .leftArrow ? -1 : 1)
            }
            showControls()
        case .upArrow:
            // Rows: options -> time bar -> transport, nothing past the top. Live with
            // a zap list keeps Up/Down for channels.
            if request.isLive && !request.zapList.isEmpty { zap(by: -1) }
            else { controls.moveRow(down: false); showControls() }
        case .downArrow:
            if request.isLive && !request.zapList.isEmpty { zap(by: 1) }
            else { controls.moveRow(down: true); showControls() }
        case .pageUp:
            if isPlaylist { playPreviousEpisode() }
        case .pageDown:
            if isPlaylist { playNextEpisode() }
        case .menu:
            if !zapListOverlay.isHidden {
                hideZapList()
            } else if controls.alpha > 0, controlsAllowed {
                // Anything showing: Menu clears it; only a Menu on a bare picture leaves.
                hideControls()
            } else {
                exit()
            }
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    private struct PressStandIn { let type: UIPress.PressType }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let seekCodes: Set<Int> = [UIPress.PressType.select.rawValue, 2040, 2088,
                                   UIPress.PressType.leftArrow.rawValue, UIPress.PressType.rightArrow.rawValue, 2080, 2079]
        if presses.contains(where: { seekCodes.contains($0.type.rawValue) }) {
            endHoldSeek()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endHoldSeek()
        super.pressesCancelled(presses, with: event)
    }

    private func handlePanelPress(_ type: UIPress.PressType) {
        switch (topPanel, type) {
        case (.episodes, .leftArrow): episodeStrip.move(by: -1)
        case (.episodes, .rightArrow): episodeStrip.move(by: 1)
        case (.episodes, .select), (.episodes, .playPause):
            let chosen = episodeStrip.selectedIndex
            hidePanel()
            if chosen != currentIndex { openEpisode(at: chosen) } else { togglePause() }
        case (.episodes, .downArrow), (.episodes, .menu): hidePanel()

        case (.tracks, .upArrow): trackMenu.moveRow(by: -1)
        case (.tracks, .downArrow): trackMenu.moveRow(by: 1)
        case (.tracks, .leftArrow): trackMenu.switchColumn(to: .subtitles)
        case (.tracks, .rightArrow): trackMenu.switchColumn(to: .audio)
        case (.tracks, .select), (.tracks, .playPause): applyTrackChoice(trackMenu.highlighted())
        case (.tracks, .menu): hidePanel()

        case (.info, .select), (.info, .playPause): togglePause()
        case (.info, .menu), (.info, .downArrow), (.info, .upArrow): hidePanel()
        case (.info, .leftArrow): hidePanel(); beginSeek(deltaMs: -10_000)
        case (.info, .rightArrow): hidePanel(); beginSeek(deltaMs: 30_000)
        default: break
        }
    }

    /// The bar counts as up only while fully visible; a bar mid-fade is "down", so a
    /// press then brings it back instead of pressing a pill the viewer can't see.
    private var barIsUp: Bool { controls.alpha >= 0.99 && !controls.isHidden }

    /// The buttons the bar offers right now: Previous/Next only when the playlist has
    /// an episode on that side.
    private func refreshControlList() {
        if request.isLive { controls.setControls([.playPause]); return }
        var list: [PlayerControl] = []
        if hasPreviousEpisode { list.append(.previous) }
        list += [.back, .playPause, .forward]
        if hasNextEpisode { list.append(.next) }
        list += [.subtitles, .audio]
        if isPlaylist { list.append(.episodes) }
        controls.setControls(list)
    }

    private func activateHighlightedControl() {
        guard let control = controls.highlightedControl else { return }
        switch control {
        case .previous: playPreviousEpisode()
        case .next: playNextEpisode()
        case .playPause: togglePause()
        case .back: beginSeek(deltaMs: -10_000)      // repeats while Select is held
        case .forward: beginSeek(deltaMs: 30_000)
        case .subtitles: showPanel(.tracks); trackMenu.switchColumn(to: .subtitles)
        case .audio: showPanel(.tracks); trackMenu.switchColumn(to: .audio)
        case .episodes: showPanel(.episodes)
        }
    }

    private func togglePause() {
        if player.isPlaying {
            wantsPlaying = false
            player.pause()
        } else {
            wantsPlaying = true
            if player.state == .ended || player.state == .stopped || player.state == .error {
                // Nothing to resume into: re-open where we were.
                reopenCurrent(at: lastKnownPositionMs)
            } else {
                player.play()
            }
        }
        if controlsAllowed { showControls() }
        refreshPauseOverlay()
        saveProgress()
    }

    // MARK: Seeking

    /// First press seeks once; holding the button keeps seeking with a growing step
    /// (1x,1x,2x,2x,4x,... up to 16x), and quick repeated taps accelerate the same way.
    private func beginSeek(deltaMs: Int) {
        guard !request.isLive else { return }
        holdDeltaMs = deltaMs
        seek(by: nextSeekStep(base: deltaMs))
        holdSeekTimer?.invalidate()
        holdSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.seek(by: self.nextSeekStep(base: self.holdDeltaMs))
        }
    }

    private func endHoldSeek() {
        holdSeekTimer?.invalidate()
        holdSeekTimer = nil
    }

    private func nextSeekStep(base: Int) -> Int {
        let now = Date()
        seekStreak = now.timeIntervalSince(lastSeekPressAt) < 0.8 ? seekStreak + 1 : 0
        lastSeekPressAt = now
        let multiplier = 1 << min(seekStreak / 2, 4)
        return base * multiplier
    }

    /// Where repeated presses have taken the playhead, before VLC is told.
    private var pendingSeekMs: Int?
    private var commitSeekTimer: Timer?

    /// Each press moves the shown position; the real seek goes to VLC once, half a
    /// second after the last press. A held button or a run of taps is therefore one
    /// provider connection, not one per step.
    private func seek(by deltaMs: Int) {
        guard !request.isLive else { return }
        let duration = Int(player.media?.length.intValue ?? 0)
        var target = (pendingSeekMs ?? Int(player.time.intValue)) + deltaMs
        target = max(0, duration > 0 ? min(target, duration - 1_000) : target)
        pendingSeekMs = target
        lastKnownPositionMs = target
        commitSeekTimer?.invalidate()
        commitSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.commitSeek() }
        let sign = deltaMs >= 0 ? "+" : "-"
        seekIndicator.text = "\(sign)\(abs(deltaMs) / 1000)s   \(PlayerFormat.clock(target))"
        seekIndicator.isHidden = false
        seekIndicatorTimer?.invalidate()
        seekIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.seekIndicator.isHidden = true
        }
        if controlsAllowed { showControls() }
    }

    private func commitSeek() {
        guard let target = pendingSeekMs else { return }
        pendingSeekMs = nil
        player.time = VLCTime(int: Int32(target))
        // VLC still says "playing" while it refills after a seek; show the wait ourselves
        // until the clock reaches the new place.
        seekTarget = (ms: target, at: Date())
        spinner.startAnimating()
        saveProgress()
    }

    // MARK: Panels and overlays

    private func showControls() {
        guard controlsAllowed else { return }
        controls.alpha = 1
        updateControls()
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Stay up while paused; while buffering, check again rather than give up,
            // or the bar would sit there until the next press.
            guard self.player.isPlaying else { return }
            timer.invalidate()
            self.controls.barFocused = false
            UIView.animate(withDuration: 0.4) { self.controls.alpha = 0 }
        }
    }

    private func hideControls() {
        controls.barFocused = false
        hideControlsTimer?.invalidate()
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
    }

    private func showPanel(_ panel: TopPanel) {
        switch panel {
        case .episodes:
            let cards = request.playlist.map { episode -> EpisodeCardModel in
                let mark = resume.mark(for: episode.mark.key)
                return EpisodeCardModel(label: "S\(episode.season) E\(episode.number)",
                                        title: episode.episodeTitle.isEmpty ? "Episode \(episode.number)" : episode.episodeTitle,
                                        image: episode.image.isEmpty ? request.poster : episode.image,
                                        progress: mark.map { $0.finished ? 1 : $0.fraction } ?? 0)
            }
            episodeStrip.configure(heading: "Episodes", episodes: cards, current: currentIndex)
        case .tracks:
            let subtitles = PlayerTracks.subtitleTracks(of: player)
            let audio = PlayerTracks.audioTracks(of: player)
            trackMenu.configure(
                subtitles: subtitles.map(\.name),
                selectedSubtitle: subtitles.firstIndex { $0.id == player.currentVideoSubTitleIndex },
                audio: audio.map(\.name),
                selectedAudio: audio.firstIndex { $0.id == player.currentAudioTrackIndex })
        case .info:
            infoPanel.setMeta(infoMeta())
        case .none:
            break
        }
        topPanel = panel
        UIView.animate(withDuration: 0.25) {
            self.episodeStrip.alpha = panel == .episodes ? 1 : 0
            self.trackMenu.alpha = panel == .tracks ? 1 : 0
            self.infoPanel.alpha = (panel == .info || self.shouldShowPauseOverlay) ? 1 : 0
        }
    }

    private func hidePanel() {
        topPanel = .none
        UIView.animate(withDuration: 0.25) {
            self.episodeStrip.alpha = 0
            self.trackMenu.alpha = 0
            self.infoPanel.alpha = self.shouldShowPauseOverlay ? 1 : 0
        }
    }

    /// The info panel doubles as the pause overlay (Android's `pauseOverlay`): it comes up
    /// on its own while paused, which for live is the only on-screen sign that the picture
    /// is frozen on purpose.
    private var shouldShowPauseOverlay: Bool {
        !wantsPlaying && (player.state == .paused || player.state == .ended) && !upNextPending
    }

    private func refreshPauseOverlay() {
        guard topPanel == .none || topPanel == .info else { return }
        if shouldShowPauseOverlay { infoPanel.setMeta(infoMeta()) }
        UIView.animate(withDuration: 0.25) {
            self.infoPanel.alpha = (self.topPanel == .info || self.shouldShowPauseOverlay) ? 1 : 0
        }
    }

    private func updateControls() {
        let position = pendingSeekMs ?? Int(player.time.intValue)
        let duration = Int(player.media?.length.intValue ?? 0)
        controls.update(positionMs: position, durationMs: duration, bufferedMs: estimatedBufferedMs(position: position),
                        isPlaying: player.isPlaying, isBuffering: spinner.isAnimating)
    }

    /// VLC does not expose a buffered position. The input statistics do say how many
    /// bytes were read versus demuxed, and the demuxed byte rate over the played time
    /// converts the difference into milliseconds. Shown as a pale extension of the bar.
    private func estimatedBufferedMs(position: Int) -> Int {
        // VOD: what is actually on disk from the playhead onward, which is what
        // "safe to seek into" means now that playback reads from the local store.
        if !request.isLive, let entry = app.mediaStore.entry(for: currentRemoteURL), entry.totalLength > 0,
           lastKnownDurationMs > 0 {
            let bytesPerMs = Double(entry.totalLength) / Double(lastKnownDurationMs)
            let chunk = Int(Double(position) * bytesPerMs) / MediaStore.chunkSize
            var end = chunk
            while entry.has(chunk: end) { end += 1 }
            let bytes = Double(end) * Double(MediaStore.chunkSize)
            return Int(min(Double(lastKnownDurationMs), bytes / bytesPerMs))
        }
        guard position > 2_000, let media = player.media else { return position }
        let stats = media.statistics
        let demuxed = Double(stats.demuxReadBytes)
        let read = Double(stats.readBytes)
        guard demuxed > 0, read > demuxed else { return position }
        let bytesPerMs = demuxed / Double(position)
        guard bytesPerMs > 0 else { return position }
        return position + Int((read - demuxed) / bytesPerMs)
    }

    // MARK: Episode flow

    /// One-second heartbeat: time bar, the "next episode" hint in the last two minutes,
    /// queuing the next episode into Continue Watching, and marking a title finished.
    private func tick() {
        guard !hasExited else { return }
        let position = Int(player.time.intValue)
        let duration = Int(player.media?.length.intValue ?? 0)
        if position > 0 { lastKnownPositionMs = position }
        if duration > 0 { lastKnownDurationMs = duration }
        if controls.alpha > 0 { updateControls() }

        guard !request.isLive, duration > 0 else { return }
        let remaining = duration - position
        let inLastTwoMinutes = remaining <= 120_000 && remaining > 1_000

        if isPlaylist {
            let showHint = inLastTwoMinutes && hasNextEpisode && !upNextPending && !nextHintDismissed
            if showHint && nextHint.isHidden { nextHint.isHidden = false }
            else if !showHint && !upNextPending && !nextHint.isHidden { hideNextHint() }

            // Under two minutes left this episode counts as watched: queue the next one so
            // Continue Watching (and the series page's Resume) point there.
            if inLastTwoMinutes && hasNextEpisode && !nextUpRecorded {
                nextUpRecorded = true
                recordNextUp()
                // Pull the next episode's opening in now so the hand-off is seamless.
                app.prefetch(request.playlist[currentIndex + 1].url, fromFraction: 0, allowWhilePlaying: true)
            }
        }
        if remaining <= 120_000 && !finishedRecorded && (!isPlaylist || !hasNextEpisode) {
            // A movie or final episode in its last two minutes is finished for resume purposes.
            finishedRecorded = true
            markFinished()
        }
    }

    /// Mirrors Android's `nearlyFinished` + `rememberNextUp`: the current episode is
    /// written as finished first, then the next one is remembered, so the next episode
    /// is the series' newest mark and Continue Watching / Resume point at it. Progress
    /// saves for the current episode stop here (see `saveProgress`) so they cannot make
    /// it newest again; a seek back out of the last two minutes resumes saving.
    private func recordNextUp() {
        finishedRecorded = true
        markFinished()
        let next = request.playlist[currentIndex + 1]
        if let existing = resume.mark(for: next.mark.key), existing.positionMs > 5_000 { return }
        var mark = next.mark
        mark.positionMs = 0
        resume.remember(mark)
    }

    private func markFinished() {
        guard let mark = currentMark, lastKnownDurationMs > 0 else { return }
        // `finished` is derived from position/duration, so writing the position at the end
        // is how a mark becomes finished without changing ResumeStore.
        resume.update(key: mark.key, positionMs: lastKnownDurationMs, durationMs: lastKnownDurationMs)
    }

    /// End of an episode with another to follow: hold on the last frame and offer the
    /// next one for eight seconds, then roll into it unless the viewer says to stay.
    private func showUpNext() {
        guard hasNextEpisode else { return }
        let next = request.playlist[currentIndex + 1]
        upNextPending = true
        hideNextHint()
        hideControls()
        upNextCard.configure(title: next.episodeTitle.isEmpty ? "S\(next.season) E\(next.number)" : "S\(next.season) E\(next.number)  ·  \(next.episodeTitle)",
                             plot: next.plot, image: next.image.isEmpty ? request.poster : next.image)
        upNextSecondsLeft = 8
        upNextCard.setCountdown(seconds: upNextSecondsLeft)
        upNextCard.isHidden = false
        NSLog("PLAYER upnext shown")
        upNextTimer?.invalidate()
        upNextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.upNextPending else { return }
            self.upNextSecondsLeft -= 1
            if self.upNextSecondsLeft <= 0 { self.playNextEpisode() }
            else { self.upNextCard.setCountdown(seconds: self.upNextSecondsLeft) }
        }
    }

    private func cancelUpNext() {
        upNextPending = false
        upNextTimer?.invalidate()
        upNextTimer = nil
        upNextCard.isHidden = true
    }

    private func hideNextHint() { nextHint.isHidden = true }

    private func playNextEpisode() {
        guard hasNextEpisode else { return }
        openEpisode(at: currentIndex + 1)
    }

    private func playPreviousEpisode() {
        guard hasPreviousEpisode else { return }
        openEpisode(at: currentIndex - 1)
    }

    // MARK: Tracks

    /// Apply the remembered subtitle choice and prefer English audio when the file offers
    /// several languages. Runs after tracks are known; harmless to call more than once.
    /// One memory per title: every episode of a series shares its series key.
    private var trackMemoryKey: String {
        if let mark = currentMark {
            return mark.kind == .series ? ResumeStore.seriesKey(mark.entryId) : mark.key
        }
        return request.mark?.key ?? ""
    }

    private func applyTrackPreferences() {
        guard !request.isLive else { return }
        let audio = PlayerTracks.audioTracks(of: player)
        let subtitles = PlayerTracks.subtitleTracks(of: player)
        guard !audio.isEmpty || !subtitles.isEmpty else { return }
        tracksApplied = true

        let remembered = PlayerPreferences.titleTracks(for: trackMemoryKey)

        // Audio: what the viewer picked for this title before, else the language rule.
        if let picked = remembered.audio, let track = audio.first(where: { $0.matches(picked) }) {
            if player.currentAudioTrackIndex != track.id { player.currentAudioTrackIndex = track.id }
        } else if audio.count > 1, let wanted = Self.preferredAudio(among: audio, originalLanguage: request.originalLanguage),
                  player.currentAudioTrackIndex != wanted.id {
            player.currentAudioTrackIndex = wanted.id
        }

        // Subtitles: the per-title pick (on with a language, or explicitly off) beats
        // the global default.
        if remembered.subtitlesOff == true {
            if player.currentVideoSubTitleIndex >= 0 { player.currentVideoSubTitleIndex = -1 }
        } else if let picked = remembered.subtitle, let track = subtitles.first(where: { $0.matches(picked) }) {
            if player.currentVideoSubTitleIndex != track.id { player.currentVideoSubTitleIndex = track.id }
        } else if PlayerPreferences.subtitlesEnabled {
            let wanted = PlayerPreferences.subtitleLanguage
            let chosen = subtitles.first { $0.matches(wanted) } ?? subtitles.first { $0.matches("en") } ?? subtitles.first
            if let chosen, player.currentVideoSubTitleIndex != chosen.id {
                player.currentVideoSubTitleIndex = chosen.id
            }
        } else if player.currentVideoSubTitleIndex >= 0 {
            player.currentVideoSubTitleIndex = -1
        }
    }

    /// The audio track to start with. The original language wins when it is one the
    /// household speaks (English, Hindi, Nepali); for anything else the dub order is
    /// Nepali, Hindi, English; failing all of those, the original.
    static func preferredAudio(among audio: [PlayerTrack], originalLanguage: String) -> PlayerTrack? {
        let spoken = ["en", "hi", "ne"]
        let original = originalLanguage.lowercased()
        if spoken.contains(original), let track = audio.first(where: { $0.matches(original) }) { return track }
        for code in ["ne", "hi", "en"] {
            if let track = audio.first(where: { $0.matches(code) }) { return track }
        }
        if !original.isEmpty, let track = audio.first(where: { $0.matches(original) }) { return track }
        return nil
    }

    private func applyTrackChoice(_ choice: TrackMenuView.Choice) {
        switch choice.column {
        case .subtitles:
            let subtitles = PlayerTracks.subtitleTracks(of: player)
            var memory = PlayerPreferences.titleTracks(for: trackMemoryKey)
            if choice.row == 0 {
                player.currentVideoSubTitleIndex = -1
                PlayerPreferences.subtitlesEnabled = false
                memory.subtitlesOff = true; memory.subtitle = nil
            } else if subtitles.indices.contains(choice.row - 1) {
                let track = subtitles[choice.row - 1]
                player.currentVideoSubTitleIndex = track.id
                PlayerPreferences.subtitlesEnabled = true
                PlayerPreferences.subtitleLanguage = track.language.isEmpty ? track.name : track.language
                memory.subtitle = track.language.isEmpty ? track.name : track.language; memory.subtitlesOff = false
            }
            PlayerPreferences.setTitleTracks(memory, for: trackMemoryKey)
        case .audio:
            let audio = PlayerTracks.audioTracks(of: player)
            if audio.indices.contains(choice.row) {
                let track = audio[choice.row]
                player.currentAudioTrackIndex = track.id
                var memory = PlayerPreferences.titleTracks(for: trackMemoryKey)
                memory.audio = track.language.isEmpty ? track.name : track.language
                PlayerPreferences.setTitleTracks(memory, for: trackMemoryKey)
            }
        }
        trackMenu.markChecked(choice)
        hidePanel()
    }

    // MARK: Progress

    private func saveProgress() {
        guard let mark = currentMark, !request.isLive else { return }
        let position = Int(player.time.intValue)
        let duration = Int(player.media?.length.intValue ?? 0)
        // Nothing meaningful happened yet; a mark at 0:02 would only clobber a real one.
        guard position >= 5_000 else { return }
        if finishedRecorded && duration > 0 && position > duration - 120_000 { return }  // keep "finished"
        resume.update(key: mark.key, positionMs: position, durationMs: duration)
    }

    private func publishReturn() {
        let episode = request.playlist.indices.contains(currentIndex) ? request.playlist[currentIndex] : nil
        let mark = currentMark.flatMap { resume.mark(for: $0.key) } ?? currentMark
        let info = PlaybackReturn(
            requestId: request.id,
            resumeKey: currentMark?.key,
            playlistIndex: currentIndex,
            season: episode?.season ?? mark?.season ?? 0,
            episode: episode?.number ?? mark?.episode ?? 0,
            positionMs: mark?.positionMs ?? lastKnownPositionMs,
            durationMs: mark?.durationMs ?? lastKnownDurationMs,
            finished: mark?.finished ?? false)
        // Off the current run loop turn: this fires from viewWillDisappear during a SwiftUI
        // dismissal, and publishing mid-update draws a runtime warning.
        let exited = hasExited
        let onReturn = request.onReturn
        DispatchQueue.main.async {
            PlaybackReturnStore.shared.last = info
            if exited { onReturn?(info) }
        }
    }

    // MARK: Live watchdog and recovery

    /// Live streams wedge without ever reporting an error: the player sits buffering or the
    /// clock stops moving. Check every two seconds and re-open after 20s of that. Live
    /// never gives up; a channel left on for hours will outlast any retry budget.
    private func startLiveWatchdog() {
        guard request.isLive else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.wantsPlaying, !self.hasExited else { return }
            let position = Int(self.player.time.intValue)
            let stuck = self.player.state == .buffering
                || (self.player.state == .playing && position == self.lastLivePositionMs)
            if stuck {
                if let since = self.liveStalledSince {
                    if Date().timeIntervalSince(since) > 20 {
                        self.liveRetries += 1
                        self.recoverLive(after: 0)
                    }
                } else {
                    self.liveStalledSince = Date()
                }
            } else {
                self.liveStalledSince = nil
            }
            self.lastLivePositionMs = position
        }
    }

    /// 1.5s, 3s, 6s, 12s, then every 15s for as long as the outage lasts.
    private func liveBackoff() -> TimeInterval {
        min(15, 1.5 * Double(1 << max(0, min(liveRetries - 1, 3))))
    }

    private func recoverLive(after delay: TimeInterval) {
        liveStalledSince = nil
        scheduleReopen(after: delay, at: 0)
    }

    private func scheduleReopen(after delay: TimeInterval, at positionMs: Int) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasExited else { return }
            self.reopenCurrent(at: positionMs)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reopenCurrent(at positionMs: Int) {
        player.stop()
        if request.playlist.indices.contains(currentIndex) {
            openMedia(url: request.playlist[currentIndex].url, startMs: positionMs)
        } else {
            openMedia(url: request.isLive ? liveUrl : request.url, startMs: positionMs)
        }
    }

    /// Live zapping: Up/Down move through the list the channel was opened from.
    /// Up/Down move the highlight in the channel column at once; the switch itself
    /// happens half a second after the last press, so stepping through channels is
    /// one stream open, not one per step, and the column is drawn before the player
    /// blocks the main thread to stop and reopen.
    private var zapCommitTimer: Timer?

    private func zap(by delta: Int) {
        guard request.isLive, !request.zapList.isEmpty else { return }
        let count = request.zapList.count
        zapIndex = ((zapIndex + delta) % count + count) % count
        let channel = request.zapList[zapIndex]
        currentTitle = channel.displayTitle
        controls.configure(title: currentTitle, subtitle: "\(zapIndex + 1) / \(count)", isLive: true)
        showZapList(hideAfter: 10)   // stays while stepping; the commit sets the real fade
        zapCommitTimer?.invalidate()
        zapCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.commitZap() }
    }

    private func commitZap() {
        guard request.isLive, request.zapList.indices.contains(zapIndex) else { return }
        let channel = request.zapList[zapIndex]
        let url = client.liveUrl(channel)
        guard url != liveUrl else { showZapList(); return }   // stepped away and back
        liveUrl = url
        liveRetries = 0
        hideNotice()
        infoPanel.configure(title: currentTitle, meta: "Live", plot: "", poster: channel.logo)
        player.stop()
        openMedia(url: liveUrl, startMs: 0)
        showZapList()
        Task { @MainActor in
            LiveMemory.shared.recordPlay(channel.id)
            // The guide line for the new channel, when the provider has one.
            let line = await client.shortEpg(streamId: channel.id).nowNextLine
            if !line.isEmpty {
                guard liveUrl == client.liveUrl(channel) else { return }
                controls.configure(title: currentTitle, subtitle: line, isLive: true)
            }
        }
    }

    // MARK: Failure handling

    /// A refused connection on an Xtream account almost always means another device holds
    /// the only slot. Say so, then keep retrying with backoff: the slot frees when the
    /// other screen stops, and the viewer should not have to back out and come back.
    private var vodRetries = 0

    private func handleFailure() {
        spinner.stopAnimating()
        NSLog("PLAYER failure live=%d limitSeen=%d retries=%d pos=%d vlc=%@", request.isLive ? 1 : 0,
              connectionLimitRecentlySeen ? 1 : 0, vodRetries, lastKnownPositionMs, VlcLogWatcher.shared.lastError)
        if request.isLive {
            liveRetries += 1
            if connectionLimitRecentlySeen { showConnectionNotice() }
            recoverLive(after: liveBackoff())
            return
        }
        if connectionLimitRecentlySeen {
            connectionRetries += 1
            showConnectionNotice()
            let delay = min(60, 3 * Double(1 << max(0, min(connectionRetries - 1, 4))))
            scheduleReopen(after: delay, at: lastKnownPositionMs)
            return
        }
        // The local stream can drop when the provider is slow; try again a few times
        // from where we were before calling the file broken.
        if vodRetries < 3 {
            vodRetries += 1
            notice.text = "Stream interrupted, retrying..."
            notice.isHidden = false
            scheduleReopen(after: 2, at: lastKnownPositionMs)
            return
        }
        notice.text = "Could not play this stream."
        notice.isHidden = false
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.exit() }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private var connectionLimitRecentlySeen: Bool {
        guard let seen = connectionLimitSeenAt else { return false }
        return Date().timeIntervalSince(seen) < 30
    }

    private func showConnectionNotice() {
        let attempt = request.isLive ? liveRetries : connectionRetries
        let counts = connectionCounts.isEmpty ? "" : " (\(connectionCounts))"
        notice.text = "Connection limit reached\(counts). Another device is using the connection.\n"
            + "Retrying automatically (retry \(attempt)). Playback continues as soon as the connection frees up."
        notice.isHidden = false
        if connectionCounts.isEmpty {
            // Fill in "(1/1)" from the account once; the player API call is cheap and the
            // number is what makes the message believable.
            Task { [weak self] in
                guard let account = try? await self?.client.checkAccount() else { return }
                await MainActor.run {
                    guard let self, !self.hasExited else { return }
                    self.connectionCounts = account.connections
                    if !self.notice.isHidden { self.showConnectionNotice() }
                }
            }
        }
    }

    private func hideNotice() {
        guard !notice.isHidden else { return }
        notice.isHidden = true
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ notification: Notification) {
        guard !hasExited else { return }
        NSLog("PLAYER state %d played=%d next=%d pos=%d", player.state.rawValue, hasPlayedSinceOpen ? 1 : 0, hasNextEpisode ? 1 : 0, Int(player.time.intValue))
        switch player.state {
        case .playing:
            spinner.stopAnimating()
            hideNotice()
            liveRetries = 0            // healthy again: the next outage starts from a short backoff
            connectionRetries = 0
            vodRetries = 0
            liveStalledSince = nil
            if !hasPlayedSinceOpen {
                hasPlayedSinceOpen = true
                // start-time normally lands us here already; seek only when it did not.
                if pendingStartMs > 0, !request.isLive, abs(Int(player.time.intValue) - pendingStartMs) > 3000 {
                    player.time = VLCTime(int: Int32(pendingStartMs))
                }
                // Tracks arrive with the first frames but subtitles can trail; apply now and
                // once more shortly after so neither is missed.
                applyTrackPreferences()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.applyTrackPreferences() }
            }
            refreshPauseOverlay()
            if controls.alpha > 0 { updateControls() }
        case .paused:
            spinner.stopAnimating()
            saveProgress()             // save the moment playback is paused
            refreshPauseOverlay()
            if controls.alpha > 0 { updateControls() }
        case .buffering:
            if !player.isPlaying { spinner.startAnimating() }
            if controls.alpha > 0 { updateControls() }
        case .esAdded:
            if !tracksApplied, hasPlayedSinceOpen { applyTrackPreferences() }
        case .error:
            hasPlayedSinceOpen = false   // the `.stopped` that follows is not an ending
            handleFailure()
        case .ended, .stopped:
            // VLC also posts `.stopped` for our own stop() calls and after errors; only an
            // item that actually played since it was opened has genuinely ended, and it
            // ends once (a trailing `.stopped` after `.ended` must not re-run this).
            guard hasPlayedSinceOpen, Date().timeIntervalSince(openedAt) > 2 else { return }
            hasPlayedSinceOpen = false
            if request.isLive {
                // A live stream never ends on purpose: the server dropped us.
                liveRetries += 1
                recoverLive(after: liveBackoff())
            } else if hasNextEpisode {
                markFinished()
                wantsPlaying = false
                showUpNext()
            } else {
                finishedRecorded = true
                markFinished()
                exit()
            }
        default:
            break
        }
    }

    private var seekTarget: (ms: Int, at: Date)?

    func mediaPlayerTimeChanged(_ notification: Notification) {
        if spinner.isAnimating {
            // A tick from before the seek landed does not count; one near the target does.
            if let seekTarget, Date().timeIntervalSince(seekTarget.at) < 0.4,
               abs(Int(player.time.intValue) - seekTarget.ms) > 5000 { return }
            self.seekTarget = nil
            spinner.stopAnimating()
            if controls.alpha > 0 { updateControls() }
        }
        if !firstFrameLogged {
            // Startup timing, so "is it faster?" is a measurement, not a feeling. VLC has no
            // rendered-first-frame callback; the first clock tick is the nearest thing.
            firstFrameLogged = true
            let ms = Int(Date().timeIntervalSince(openedAt) * 1000)
            print("XtreamPerf first-frame \(ms)ms live=\(request.isLive) resume=\(pendingStartMs > 0)")
        }
        if controls.alpha > 0 { updateControls() }
    }
}
