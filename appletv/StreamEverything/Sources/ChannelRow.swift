import SwiftUI

/// One live-channel row: station logo (or the last previewed still), name with a
/// favorite/played marker and a catch-up badge, and a lazily loaded now/next guide
/// line. Select plays; a long press offers favorite, play and remove (removed channels
/// gather in the Removed list); play/pause also plays.
struct ChannelRow: View {
    let channel: Entry
    let isFavorite: Bool
    let played: Bool
    let hasArchive: Bool
    var isRemoved = false
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    var onToggleRemoved: (() -> Void)? = nil

    @EnvironmentObject private var app: AppState
    @ObservedObject private var stills = PreviewStills.shared
    @State private var guideLine = "…"

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .center, spacing: 24) {
                artwork
                    .frame(width: 240, height: 135)
                    .background(Color(red: 0.13, green: 0.19, blue: 0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isFavorite {
                            Text("♥").foregroundStyle(Color(red: 1, green: 0.4, blue: 0.5))
                        } else if played {
                            Text("★").foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                        }
                        Text(channel.displayTitle).font(.headline).lineLimit(1)
                        if hasArchive {
                            Text("⟲ catch-up").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(guideLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // Holding Select on a focused button opens the context menu on tvOS; the
        // SwiftUI long-press gesture never fires there.
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { onToggleFavorite() }
            Button("Play") { onPlay() }
            if let onToggleRemoved {
                if isRemoved {
                    Button("Put back in the lists") { onToggleRemoved() }
                } else {
                    Button("Remove from the list", role: .destructive) { onToggleRemoved() }
                }
            }
        }
        .onPlayPauseCommand(perform: onPlay)
        .task(id: channel.id) { await loadGuide() }
    }

    /// A recently previewed channel shows its last frame; otherwise the logo.
    @ViewBuilder
    private var artwork: some View {
        if let still = stills.image(for: channel.id) {
            Image(uiImage: still).resizable().aspectRatio(contentMode: .fill)
        } else {
            CachedImage(url: URL(string: channel.logo)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit).padding(16)
                } else {
                    Image(systemName: "tv").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Cache hit paints at once; a miss fetches once (the cache dedupes concurrent
    /// asks) and the result is dropped if the row moved on to another channel.
    private func loadGuide() async {
        let id = channel.id
        if let cached = await app.client.shortEpgCached(streamId: id) {
            guideLine = cached.nowNextLine
            return
        }
        guideLine = "…"
        let programs = await app.client.shortEpg(streamId: id)
        guard !Task.isCancelled, channel.id == id else { return }
        guideLine = programs.nowNextLine
    }
}

/// A short confirmation that fades out, standing in for Android's Toast.
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct ToastOverlay: View {
    @Binding var toast: ToastMessage?

    var body: some View {
        VStack {
            Spacer()
            if let toast {
                Text(toast.text)
                    .font(.callout)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(2))
                        if self.toast?.id == toast.id { withAnimation { self.toast = nil } }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toast)
        .allowsHitTesting(false)
    }
}
