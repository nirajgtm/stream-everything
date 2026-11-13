import Foundation
import UIKit
import TVVLCKit

// MARK: - Preferences

/// Small settings the player remembers between videos. UserDefaults is enough: these
/// are a handful of scalars and they must survive restarts, not sync anywhere.
enum PlayerPreferences {
    private static let defaults = UserDefaults.standard
    private static let subtitlesEnabledKey = "subtitlesEnabled"
    private static let subtitleLanguageKey = "subtitleLanguage"
    private static let liveControlsKey = "liveControls"

    /// Whether subtitles come on automatically for every video. Off by default, like
    /// the Android app, because most of this catalog is already in the viewer's language.
    static var subtitlesEnabled: Bool {
        get { defaults.bool(forKey: subtitlesEnabledKey) }
        set { defaults.set(newValue, forKey: subtitlesEnabledKey) }
    }

    /// Language code or track name the viewer last picked ("en", "eng", "English", ...).
    /// Empty means "whatever is first".
    static var subtitleLanguage: String {
        get { defaults.string(forKey: subtitleLanguageKey) ?? "" }
        set { defaults.set(newValue, forKey: subtitleLanguageKey) }
    }

    /// Tracks the viewer picked by hand for one title (a movie, or a whole series),
    /// keyed by the title's resume key. An explicit pick must survive a resume, so it
    /// is stored per title rather than folded into the global defaults.
    struct TitleTracks: Codable { var audio: String?; var subtitle: String?; var subtitlesOff: Bool? }

    static func titleTracks(for key: String) -> TitleTracks {
        guard !key.isEmpty, let data = defaults.data(forKey: "tracks." + key),
              let saved = try? JSONDecoder().decode(TitleTracks.self, from: data) else { return TitleTracks() }
        return saved
    }

    static func setTitleTracks(_ tracks: TitleTracks, for key: String) {
        guard !key.isEmpty, let data = try? JSONEncoder().encode(tracks) else { return }
        defaults.set(data, forKey: "tracks." + key)
    }

    /// Live TV hides the time bar by default so the picture stays clean; a settings
    /// screen can flip this on for viewers who want to see the bar while zapping.
    static var liveControls: Bool {
        get { defaults.bool(forKey: liveControlsKey) }
        set { defaults.set(newValue, forKey: liveControlsKey) }
    }
}

// MARK: - Return info for the series page

/// What was on screen when the player closed, so the page underneath can land on the
/// episode that was actually playing (which may differ from the one it launched).
struct PlaybackReturn: Equatable {
    let requestId: UUID
    /// Resume key of the episode or movie last playing (nil for live).
    let resumeKey: String?
    /// Index into the playlist that was playing; 0 for a single item.
    let playlistIndex: Int
    let season: Int
    let episode: Int
    let positionMs: Int
    let durationMs: Int
    let finished: Bool
}

/// Published copy of the last `PlaybackReturn`. A `fullScreenCover` gives the presenting
/// view no result value, so the series page observes this instead and reads `last`
/// after the cover is dismissed (or compares `requestId` to the request it launched).
final class PlaybackReturnStore: ObservableObject {
    static let shared = PlaybackReturnStore()
    @Published var last: PlaybackReturn?
}

// MARK: - libvlc log watcher

/// Listens to libvlc's own log stream to learn *why* a stream failed. VLCKit only
/// reports an opaque `.error` state, but the HTTP access module logs the status code,
/// and on an Xtream account the one that matters is 458 ("connection limit reached").
/// A single watcher is installed library-wide; the active player registers for events.
final class VlcLogWatcher: NSObject, VLCLogging {
    static let shared = VlcLogWatcher()

    /// Called on the main thread when a message looks like a connection-limit refusal.
    var onConnectionLimit: (() -> Void)?

    var level: VLCLogLevel = .warning

    private override init() {
        super.init()
    }

    /// Idempotent: VLCLibrary keeps one loggers array, so installing twice is harmless.
    func install() {
        let library = VLCLibrary.shared()
        let existing = library.loggers ?? []
        if existing.contains(where: { $0 === self }) { return }
        library.loggers = existing + [self]
    }

    /// The last error-level line VLC logged, for the failure log.
    private(set) var lastError = ""

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let text = message.lowercased()
        if level == .error { lastError = message }
        // "458" must be a status code, not three digits inside a byte count.
        let refused = text.range(of: #"(status|code|http[^0-9]{0,8})\D{0,8}\b458\b"#, options: .regularExpression) != nil
            || text.contains("connection limit")
            || text.contains("too many connections")
        guard refused else { return }
        DispatchQueue.main.async { [weak self] in self?.onConnectionLimit?() }
    }
}

// MARK: - Track helpers

/// One selectable audio or subtitle track: the id VLC wants back, a display name, and
/// a language code when the container carries one.
struct PlayerTrack: Equatable {
    let id: Int32
    let name: String
    let language: String

    /// True when this track is the one the viewer asked for by language or name.
    /// "en", "eng" and "English" all mean the same thing to a viewer, so compare loosely.
    func matches(_ wanted: String) -> Bool {
        let want = wanted.lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return false }
        let lang = language.lowercased()
        let label = name.lowercased()
        if lang == want || label == want { return true }
        if lang.hasPrefix(want) || want.hasPrefix(lang), !lang.isEmpty { return true }
        if label.contains(want) { return true }
        // Common two- vs three-letter code pairs that show up in IPTV containers.
        let families: [Set<String>] = [
            ["en", "eng", "english"], ["hi", "hin", "hindi"], ["ne", "nep", "nepali"],
            ["ja", "jpn", "japanese"], ["ko", "kor", "korean"], ["es", "spa", "spanish"], ["fr", "fre", "fra", "french"],
            ["de", "ger", "deu", "german"], ["it", "ita", "italian"], ["pt", "por", "portuguese"], ["ar", "ara", "arabic"],
            ["ta", "tam", "tamil"], ["te", "tel", "telugu"], ["ml", "mal", "malayalam"], ["kn", "kan", "kannada"], ["zh", "chi", "zho", "chinese", "mandarin"]
        ]
        if let family = families.first(where: { $0.contains(want) }) {
            if family.contains(lang) { return true }
            if family.contains(where: { $0.count > 3 && label.contains($0) }) { return true }
        }
        return false
    }
}

enum PlayerTracks {
    /// Audio tracks as VLC lists them, enriched with language codes from the media's
    /// track information when the ids line up.
    static func audioTracks(of player: VLCMediaPlayer) -> [PlayerTrack] {
        build(ids: player.audioTrackIndexes, names: player.audioTrackNames,
              languages: languages(in: player.media, type: VLCMediaTracksInformationTypeAudio))
    }

    /// Subtitle tracks, with the "Disable" pseudo-track VLC inserts filtered out.
    static func subtitleTracks(of player: VLCMediaPlayer) -> [PlayerTrack] {
        build(ids: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames,
              languages: languages(in: player.media, type: VLCMediaTracksInformationTypeText))
            .filter { $0.id >= 0 }
    }

    private static func build(ids: [Any]?, names: [Any]?, languages: [Int32: String]) -> [PlayerTrack] {
        let idList = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let nameList = (names ?? []).map { ($0 as? String) ?? "" }
        var out: [PlayerTrack] = []
        for (position, id) in idList.enumerated() {
            let rawName = position < nameList.count ? nameList[position] : ""
            // VLC names look like "Track 1 - [English]"; strip the bracket noise.
            let name = rawName.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            out.append(PlayerTrack(id: id, name: name.isEmpty ? "Track \(position + 1)" : name,
                                   language: languages[id] ?? ""))
        }
        return out
    }

    /// Map of elementary-stream id to ISO language code for one track type.
    private static func languages(in media: VLCMedia?, type: String) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for case let info as [String: Any] in media?.tracksInformation ?? [] {
            guard (info[VLCMediaTracksInformationType] as? String) == type,
                  let id = (info[VLCMediaTracksInformationId] as? NSNumber)?.int32Value else { continue }
            out[id] = (info[VLCMediaTracksInformationLanguage] as? String) ?? ""
        }
        return out
    }
}

// MARK: - Images

/// Tiny poster loader for the UIKit overlays. SwiftUI's AsyncImage is not usable from a
/// UIView, and the player only ever needs a few small images, so a cache plus a token
/// check (so a late response never lands on a reused image view) is all it takes.
final class PlayerImageLoader {
    static let shared = PlayerImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var tokens: [ObjectIdentifier: UUID] = [:]

    func load(_ urlString: String, into imageView: UIImageView) {
        let token = UUID()
        tokens[ObjectIdentifier(imageView)] = token
        imageView.image = nil
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        if let cached = ImageStore.shared.cachedImage(for: url, maxDim: 800) {
            imageView.image = cached
            return
        }
        Task { [weak self, weak imageView] in
            guard let image = await ImageStore.shared.image(for: url, maxDim: 800) else { return }
            await MainActor.run {
                guard let self, let imageView, self.tokens[ObjectIdentifier(imageView)] == token else { return }
                imageView.image = image
            }
        }
    }
}

// MARK: - Formatting

enum PlayerFormat {
    /// "1:02:03" or "12:03", the way a TV time bar reads.
    static func clock(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
