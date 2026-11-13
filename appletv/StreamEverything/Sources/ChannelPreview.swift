import SwiftUI
import UIKit
import TVVLCKit

/// Stills grabbed from channels that were previewed, so a row you have looked at
/// keeps showing what was on instead of snapping back to the station logo.
/// Kept five minutes; after that a frame says nothing about what is on now.
@MainActor
final class PreviewStills: ObservableObject {
    static let shared = PreviewStills()
    private var frames: [Int: (image: UIImage, takenAt: Date)] = [:]
    private let ttl: TimeInterval = 5 * 60
    /// Bumped on every new frame so rows showing a still re-render.
    @Published private(set) var version = 0

    func image(for channelId: Int) -> UIImage? {
        guard let hit = frames[channelId], Date().timeIntervalSince(hit.takenAt) < ttl else { return nil }
        return hit.image
    }

    func store(_ image: UIImage, for channelId: Int) {
        frames[channelId] = (image, Date())
        version += 1
    }
}

/// One live preview, with sound, that follows the focused channel row. It starts
/// only after a short dwell so scrolling quickly through a list does not thrash the
/// decoder, and only one channel ever previews at a time. While it plays, a still
/// is snapshotted every second into `PreviewStills`, so leaving at any moment
/// (mid-buffer included) already has a frame to show on the row.
@MainActor
final class ChannelPreviewController: NSObject, ObservableObject {
    /// Channel currently on the preview surface; nil while idle or dwelling.
    @Published private(set) var previewingChannelId: Int?
    /// Channel the dwell timer is waiting on; lets the pane show its logo meanwhile.
    @Published private(set) var pendingChannel: Entry?

    /// The surface VLC draws into. Owned here so the player can keep its drawable
    /// across SwiftUI re-renders of the pane.
    let videoView = UIView()

    private let player = VLCMediaPlayer()
    private let dwell: Duration = .milliseconds(800)
    private let snapshotEvery: Duration = .seconds(1)
    private var dwellTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private let snapshotDir: URL

    override init() {
        snapshotDir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        super.init()
        videoView.backgroundColor = .black
        player.drawable = videoView
        player.audio?.volume = 100 // the preview plays with sound, like the Android app
    }

    /// Call when the focused row changes. Passing nil (focus left the list) stops
    /// the preview, so a channel never keeps playing for a row nobody is on.
    func focusChanged(to channel: Entry?, url: URL?) {
        dwellTask?.cancel()
        dwellTask = nil
        if channel?.id == previewingChannelId, previewingChannelId != nil { return }
        stopPreview()
        guard let channel, let url else { pendingChannel = nil; return }
        pendingChannel = channel
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: self?.dwell ?? .milliseconds(800))
            guard !Task.isCancelled, let self, self.pendingChannel?.id == channel.id else { return }
            self.startPreview(channel: channel, url: url)
        }
    }

    /// Frees the decoder before full playback or when leaving the screen.
    func pause() {
        dwellTask?.cancel()
        dwellTask = nil
        pendingChannel = nil
        stopPreview()
    }

    private func startPreview(channel: Entry, url: URL) {
        let media = VLCMedia(url: url)
        // Shorter buffer than full playback: a preview should appear quickly and a
        // brief stall costs nothing here.
        media.addOption(":network-caching=1500")
        media.addOption(":http-user-agent=VLC/3.0.20 LibVLC/3.0.20")
        player.media = media
        player.play()
        previewingChannelId = channel.id
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.snapshotEvery ?? .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.captureStill(for: channel.id)
            }
        }
    }

    /// Stops playback, keeping the newest still on the row.
    private func stopPreview() {
        snapshotTask?.cancel()
        snapshotTask = nil
        if previewingChannelId != nil {
            player.stop()
            previewingChannelId = nil
        }
    }

    /// VLC writes snapshots to disk asynchronously, so the file is read back a beat
    /// later. Grabs before the first frame (no video out yet) are skipped.
    private func captureStill(for channelId: Int) async {
        guard previewingChannelId == channelId, player.hasVideoOut else { return }
        let path = snapshotDir.appendingPathComponent("\(channelId).png").path
        player.saveVideoSnapshot(at: path, withWidth: 320, andHeight: 180)
        try? await Task.sleep(for: .milliseconds(300))
        guard let image = UIImage(contentsOfFile: path) else { return }
        PreviewStills.shared.store(image, for: channelId)
    }
}

/// The pane where the preview plays: the video surface with the pending channel's
/// logo over it until the stream has a picture.
struct ChannelPreviewPane: View {
    @ObservedObject var controller: ChannelPreviewController

    var body: some View {
        ZStack {
            Color.black
            PreviewSurface(view: controller.videoView)
            if controller.previewingChannelId == nil {
                VStack(spacing: 10) {
                    if let channel = controller.pendingChannel {
                        CachedImage(url: URL(string: channel.logo)) { phase in
                            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                        }
                        .frame(maxHeight: 90)
                        Text(channel.displayTitle).font(.caption).lineLimit(1)
                    } else {
                        Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Pause on a channel to preview it").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private struct PreviewSurface: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
