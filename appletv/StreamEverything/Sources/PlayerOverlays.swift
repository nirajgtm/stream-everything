import UIKit

/// Shared look for every player overlay so the pieces read as one surface.
enum PlayerStyle {
    static let accent = UIColor(red: 0.5, green: 0.8, blue: 0.77, alpha: 1)
    static let panel = UIColor(red: 0.063, green: 0.094, blue: 0.125, alpha: 1)
    static let dimText = UIColor(red: 0.87, green: 0.89, blue: 0.91, alpha: 1)
    static let mutedText = UIColor(red: 0.62, green: 0.70, blue: 0.75, alpha: 1)
    /// Safe-area side margin for a 1080p TV.
    static let sideMargin: CGFloat = 90
    static let cornerRadius: CGFloat = 14
}

// MARK: - Progress bar

/// Time bar with three layers: track, buffered (what the network already delivered)
/// and played. A plain UIProgressView cannot show the buffered region, and that region
/// is what tells a viewer whether a stall is the network or the server.
final class PlaybackBar: UIView {
    private let track = UIView()
    private let buffered = UIView()
    private let played = UIView()
    private let knob = UIView()

    /// 0...1 fractions. Buffered is drawn under played so it only ever extends it.
    var playedFraction: CGFloat = 0 { didSet { setNeedsLayout() } }
    var bufferedFraction: CGFloat = 0 { didSet { setNeedsLayout() } }
    var showsKnob = true { didSet { knob.isHidden = !showsKnob } }
    /// Focused: the bar thickens and the knob grows with a teal ring, so it is clear
    /// Left/Right now scrub instead of walking the buttons.
    private let bubble = PillLabel()
    var scrubbing = false {
        didSet {
            knob.backgroundColor = scrubbing ? PlayerStyle.accent : .white
            knob.layer.borderWidth = scrubbing ? 5 : 0
            knob.layer.borderColor = UIColor.white.cgColor
            knob.layer.shadowColor = PlayerStyle.accent.cgColor
            knob.layer.shadowOpacity = scrubbing ? 1 : 0
            knob.layer.shadowRadius = 22
            knob.layer.shadowOffset = .zero
            knob.layer.masksToBounds = false
            track.backgroundColor = UIColor.white.withAlphaComponent(scrubbing ? 0.45 : 0.22)
            bubble.isHidden = !scrubbing
            setNeedsLayout()
        }
    }
    /// Time shown in the bubble above the knob while scrubbing.
    var bubbleText: String = "" { didSet { bubble.text = bubbleText; setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        buffered.backgroundColor = UIColor.white.withAlphaComponent(0.38)
        played.backgroundColor = PlayerStyle.accent
        knob.backgroundColor = .white
        [track, buffered, played, knob].forEach { addSubview($0); $0.layer.masksToBounds = true }
        bubble.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        bubble.fillColor = PlayerStyle.accent
        bubble.textColor = PlayerStyle.panel
        bubble.isHidden = true
        addSubview(bubble)
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height: CGFloat = scrubbing ? 16 : 8
        let y = (bounds.height - height) / 2
        let width = bounds.width
        track.frame = CGRect(x: 0, y: y, width: width, height: height)
        buffered.frame = CGRect(x: 0, y: y, width: width * min(1, max(playedFraction, bufferedFraction)), height: height)
        played.frame = CGRect(x: 0, y: y, width: width * min(1, max(0, playedFraction)), height: height)
        [track, buffered, played].forEach { $0.layer.cornerRadius = height / 2 }
        let knobSize: CGFloat = scrubbing ? 40 : 20
        knob.frame = CGRect(x: played.frame.maxX - knobSize / 2, y: (bounds.height - knobSize) / 2,
                            width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        let bubbleSize = bubble.intrinsicContentSize
        var bubbleX = knob.frame.midX - bubbleSize.width / 2
        bubbleX = max(0, min(width - bubbleSize.width, bubbleX))
        bubble.frame = CGRect(x: bubbleX, y: knob.frame.minY - bubbleSize.height - 14, width: bubbleSize.width, height: bubbleSize.height)
    }
}

// MARK: - Control buttons

/// What a control-bar button does. The order here is the order on screen.
enum PlayerControl: CaseIterable {
    case previous, playPause, back, forward, next, subtitles, audio, episodes

    var symbol: String {
        switch self {
        case .previous: "backward.end.fill"
        case .next: "forward.end.fill"
        case .playPause: "play.fill"
        case .back: "gobackward.10"
        case .forward: "goforward.30"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .episodes: "list.bullet.rectangle"
        }
    }
    var label: String {
        switch self {
        case .previous: "Previous"
        case .next: "Next"
        case .playPause: "Play"
        case .back: "10s"
        case .forward: "30s"
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .episodes: "Episodes"
        }
    }
}

/// One pill in the control bar. The highlighted one is white with dark glyph and
/// slightly larger, the same focus language the rest of the app uses, so there is
/// never a doubt which control Select will press.
final class ControlPill: UIView {
    let icon = UIImageView()
    let caption = UILabel()
    private(set) var highlighted = false
    /// Transport buttons are big round glyphs in the middle of the picture (the
    /// Netflix / Apple TV shape); the rest are labelled pills along the bottom.
    let isTransport: Bool

    /// Round transport buttons: `size` 110 for seek and play/pause, smaller for the
    /// episode steppers at the ends of the row.
    init(transport: Bool, size: CGFloat = 110) {
        isTransport = transport
        super.init(frame: .zero)
        icon.contentMode = .scaleAspectFit
        [icon, caption].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        if transport {
            layer.cornerRadius = size / 2
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
            caption.isHidden = true
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: size),
                heightAnchor.constraint(equalToConstant: size),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: size * 0.5),
                icon.heightAnchor.constraint(equalToConstant: size * 0.5),
            ])
        } else {
            layer.cornerRadius = 30
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            caption.font = .systemFont(ofSize: 22, weight: .medium)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 34),
                icon.heightAnchor.constraint(equalToConstant: 34),
                caption.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
                caption.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 60),
            ])
        }
        setHighlighted(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private lazy var spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .large)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return view
    }()

    /// A loading pill spins instead of showing its glyph.
    func setLoading(_ on: Bool) {
        guard isTransport else { return }
        icon.isHidden = on
        spinner.color = highlighted ? PlayerStyle.panel : .white
        if on { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    func setHighlighted(_ on: Bool) {
        highlighted = on
        // White pill, teal ring and a glow: readable from across the room.
        backgroundColor = on ? .white : UIColor.white.withAlphaComponent(0.18)
        icon.tintColor = on ? PlayerStyle.panel : .white
        caption.textColor = on ? PlayerStyle.panel : .white
        if icon.isHidden { spinner.color = on ? PlayerStyle.panel : .white }
        layer.borderWidth = on ? 4 : 0
        layer.borderColor = PlayerStyle.accent.cgColor
        layer.shadowColor = PlayerStyle.accent.cgColor
        layer.shadowOpacity = on ? 0.9 : 0
        layer.shadowRadius = 18
        layer.shadowOffset = .zero
        let scale: CGFloat = isTransport ? 1.12 : 1.18
        transform = on ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    }
}

// MARK: - Bottom controls

/// The bar at the bottom: title, play/pause glyph, time bar and clocks. For live it
/// collapses to the title and a LIVE badge because there is no timeline to show.
final class ControlsOverlay: UIView {
    private let gradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stateIcon = UIImageView()
    private let bar = PlaybackBar()
    private let elapsedLabel = UILabel()
    private let totalLabel = UILabel()
    private let liveBadge = PillLabel()
    private let buttonRow = UIStackView()       // transport, centre of the screen
    private let optionRow = UIStackView()       // subtitles / audio / episodes, bottom
    private var pills: [PlayerControl: ControlPill] = [:]
    private(set) var controls: [PlayerControl] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        gradient.locations = [0, 0.6, 1]
        layer.addSublayer(gradient)
        backgroundColor = UIColor.black.withAlphaComponent(0.25)   // dims the picture so the centre buttons read

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 36, weight: .semibold)
        subtitleLabel.textColor = PlayerStyle.mutedText
        subtitleLabel.font = .systemFont(ofSize: 24, weight: .regular)
        stateIcon.tintColor = .white
        stateIcon.contentMode = .scaleAspectFit
        stateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
        for label in [elapsedLabel, totalLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 26, weight: .regular)
        }
        totalLabel.textAlignment = .right
        liveBadge.text = "LIVE"
        liveBadge.font = .systemFont(ofSize: 22, weight: .bold)
        liveBadge.fillColor = UIColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 0.9)
        liveBadge.isHidden = true

        buttonRow.axis = .horizontal
        buttonRow.spacing = 60
        buttonRow.alignment = .center
        optionRow.axis = .horizontal
        optionRow.spacing = 18
        optionRow.alignment = .center
        [titleLabel, subtitleLabel, stateIcon, bar, elapsedLabel, totalLabel, liveBadge, buttonRow, optionRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        stateIcon.isHidden = true   // the play/pause pill in the row replaces the loose glyph
        let m = PlayerStyle.sideMargin
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: liveBadge.leadingAnchor, constant: -24),
            titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -22),
            liveBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            liveBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            stateIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            stateIcon.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 44),
            stateIcon.heightAnchor.constraint(equalToConstant: 44),
            bar.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 28),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            bar.heightAnchor.constraint(equalToConstant: 24),
            bar.bottomAnchor.constraint(equalTo: elapsedLabel.topAnchor, constant: -10),
            elapsedLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            elapsedLabel.bottomAnchor.constraint(equalTo: optionRow.topAnchor, constant: -16),
            buttonRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            optionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            totalLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            totalLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func configure(title: String, subtitle: String, isLive: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        liveBadge.isHidden = !isLive
        bar.isHidden = isLive
        elapsedLabel.isHidden = isLive
        totalLabel.isHidden = isLive
    }

    /// Where the remote's highlight sits: the transport buttons in the centre, the
    /// time bar, or the option pills at the bottom. Up/Down move between rows,
    /// Left/Right move inside one.
    enum Row { case transport, bar, options }
    private(set) var row: Row = .transport
    private var transportCursor = 0
    private var optionCursor = 0
    private var transportControls: [PlayerControl] { controls.filter { Self.isTransport($0) } }
    private var optionControls: [PlayerControl] { controls.filter { !Self.isTransport($0) } }
    private static func isTransport(_ c: PlayerControl) -> Bool { [PlayerControl.previous, .back, .playPause, .forward, .next].contains(c) }
    private var barAvailable: Bool { !bar.isHidden }

    /// Which buttons the bar offers; the cursor goes back to Play/Pause.
    func setControls(_ list: [PlayerControl]) {
        controls = list
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        optionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pills = [:]
        for control in list {
            let transport = Self.isTransport(control)
            let pill = ControlPill(transport: transport, size: [PlayerControl.previous, .next].contains(control) ? 84 : 110)
            pill.icon.image = UIImage(systemName: control.symbol)
            pill.caption.text = control.label
            pills[control] = pill
            (transport ? buttonRow : optionRow).addArrangedSubview(pill)
        }
        row = .transport
        transportCursor = transportControls.firstIndex(of: .playPause) ?? 0
        optionCursor = 0
        refreshHighlight()
    }

    /// Left/Right inside the current row.
    func moveCursor(by delta: Int) {
        switch row {
        case .transport:
            guard !transportControls.isEmpty else { return }
            transportCursor = max(0, min(transportControls.count - 1, transportCursor + delta))
        case .options:
            guard !optionControls.isEmpty else { return }
            optionCursor = max(0, min(optionControls.count - 1, optionCursor + delta))
        case .bar: return
        }
        refreshHighlight()
    }

    /// Down from the transport goes to the time bar, then to the options; Up goes
    /// back the same way. Returns false when there is nowhere further to go.
    @discardableResult
    func moveRow(down: Bool) -> Bool {
        let order: [Row] = [.transport] + (barAvailable ? [.bar] : []) + (optionControls.isEmpty ? [] : [.options])
        guard let index = order.firstIndex(of: row) else { row = .transport; refreshHighlight(); return true }
        let next = index + (down ? 1 : -1)
        guard order.indices.contains(next) else { return false }
        row = order[next]
        refreshHighlight()
        return true
    }

    func setCursor(to control: PlayerControl) {
        if let index = transportControls.firstIndex(of: control) { row = .transport; transportCursor = index }
        else if let index = optionControls.firstIndex(of: control) { row = .options; optionCursor = index }
        refreshHighlight()
    }

    var highlightedControl: PlayerControl? {
        switch row {
        case .transport: return transportControls.indices.contains(transportCursor) ? transportControls[transportCursor] : nil
        case .options: return optionControls.indices.contains(optionCursor) ? optionControls[optionCursor] : nil
        case .bar: return nil
        }
    }

    /// Focus on the time bar instead of a button.
    var barFocused: Bool {
        get { row == .bar }
        set { row = newValue ? .bar : .transport; refreshHighlight() }
    }

    private func refreshHighlight() {
        bar.scrubbing = row == .bar
        // The time bubble sits where the title is; give it the room.
        titleLabel.alpha = row == .bar ? 0 : 1
        subtitleLabel.alpha = row == .bar ? 0 : 1
        let lit = highlightedControl
        for control in controls { pills[control]?.setHighlighted(control == lit) }
    }

    func update(positionMs: Int, durationMs: Int, bufferedMs: Int, isPlaying: Bool, isBuffering: Bool) {
        // The pill shows the ACTION Select will take: pause while playing, play while
        // paused; while loading it spins in place, so nothing else needs to sit on it.
        if let pill = pills[.playPause] {
            pill.icon.image = UIImage(systemName: isPlaying || isBuffering ? "pause.fill" : "play.fill")
        }
        bar.bubbleText = PlayerFormat.clock(positionMs)
        if durationMs > 0 {
            bar.playedFraction = CGFloat(positionMs) / CGFloat(durationMs)
            bar.bufferedFraction = CGFloat(bufferedMs) / CGFloat(durationMs)
            elapsedLabel.text = PlayerFormat.clock(positionMs)
            totalLabel.text = "-" + PlayerFormat.clock(max(0, durationMs - positionMs))
        } else {
            bar.playedFraction = 0
            bar.bufferedFraction = 0
            elapsedLabel.text = PlayerFormat.clock(positionMs)
            totalLabel.text = ""
        }
    }
}

// MARK: - Info panel (pause overlay + Down arrow)

/// Soft panel from the top edge with the title, a meta line, the plot and a poster.
/// Shown while paused and on demand, never focused: it is reading material only.
final class InfoPanel: UIView {
    private let gradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let plotLabel = UILabel()
    private let poster = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [PlayerStyle.panel.withAlphaComponent(0.92).cgColor, PlayerStyle.panel.withAlphaComponent(0).cgColor]
        layer.addSublayer(gradient)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 44, weight: .bold)
        titleLabel.numberOfLines = 2
        metaLabel.textColor = PlayerStyle.accent
        metaLabel.font = .systemFont(ofSize: 24, weight: .medium)
        plotLabel.textColor = PlayerStyle.dimText
        plotLabel.font = .systemFont(ofSize: 26, weight: .regular)
        plotLabel.numberOfLines = 6
        poster.contentMode = .scaleAspectFill
        poster.layer.cornerRadius = PlayerStyle.cornerRadius
        poster.layer.masksToBounds = true
        poster.backgroundColor = UIColor.white.withAlphaComponent(0.06)

        [titleLabel, metaLabel, plotLabel, poster].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let m = PlayerStyle.sideMargin
        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: topAnchor, constant: 70),
            poster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            poster.widthAnchor.constraint(equalToConstant: 260),
            poster.heightAnchor.constraint(equalToConstant: 390),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 70),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(equalTo: poster.leadingAnchor, constant: -60),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            plotLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 18),
            plotLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            plotLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func configure(title: String, meta: String, plot: String, poster posterUrl: String) {
        titleLabel.text = title
        metaLabel.text = meta
        metaLabel.isHidden = meta.isEmpty
        plotLabel.text = plot
        plotLabel.isHidden = plot.isEmpty
        poster.isHidden = posterUrl.isEmpty
        if !posterUrl.isEmpty { PlayerImageLoader.shared.load(posterUrl, into: poster) }
    }

    func setMeta(_ meta: String) {
        metaLabel.text = meta
        metaLabel.isHidden = meta.isEmpty
    }
}

// MARK: - Live channel list (Up/Down zapping)

/// A column down the left edge: the channels around the current one, the current
/// one lit. Reading material while zapping; it never takes focus.
final class ZapListOverlay: UIView {
    private let gradient = CAGradientLayer()
    private let stack = UIStackView()
    private static let rows = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [PlayerStyle.panel.withAlphaComponent(0.94).cgColor, PlayerStyle.panel.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(gradient)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PlayerStyle.sideMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for _ in 0..<Self.rows {
            let label = PillLabel()
            label.font = .systemFont(ofSize: 28, weight: .medium)
            label.textAlignment = .left
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    /// The window of names around `current`, wrapping like the zap order does.
    func configure(names: [String], current: Int) {
        let labels = stack.arrangedSubviews.compactMap { $0 as? PillLabel }
        let half = Self.rows / 2
        for (slot, label) in labels.enumerated() {
            let offset = slot - half
            guard !names.isEmpty, names.count > abs(offset) || offset == 0 else { label.isHidden = true; continue }
            let index = ((current + offset) % names.count + names.count) % names.count
            label.isHidden = false
            label.text = "\(index + 1)   \(names[index])"
            let lit = offset == 0
            label.fillColor = lit ? .white : UIColor.white.withAlphaComponent(0.1)
            label.textColor = lit ? PlayerStyle.panel : .white
            label.font = .systemFont(ofSize: lit ? 30 : 26, weight: lit ? .semibold : .regular)
        }
    }
}

// MARK: - Up next

/// Card for the end-of-episode prompt: still, title, a line of plot and the countdown.
final class UpNextCard: UIView {
    private let heading = UILabel()
    private let still = UIImageView()
    private let titleLabel = UILabel()
    private let plotLabel = UILabel()
    private let countdownLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = PlayerStyle.panel.withAlphaComponent(0.94)
        layer.cornerRadius = PlayerStyle.cornerRadius
        layer.masksToBounds = true

        heading.text = "UP NEXT"
        heading.textColor = PlayerStyle.accent
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        still.contentMode = .scaleAspectFill
        still.layer.cornerRadius = 10
        still.layer.masksToBounds = true
        still.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.numberOfLines = 2
        plotLabel.textColor = PlayerStyle.dimText
        plotLabel.font = .systemFont(ofSize: 22)
        plotLabel.numberOfLines = 3
        countdownLabel.textColor = PlayerStyle.mutedText
        countdownLabel.font = .systemFont(ofSize: 22, weight: .medium)

        [heading, still, titleLabel, plotLabel, countdownLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 820),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            still.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            still.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            still.widthAnchor.constraint(equalToConstant: 320),
            still.heightAnchor.constraint(equalToConstant: 180),
            titleLabel.topAnchor.constraint(equalTo: still.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: still.trailingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            plotLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            plotLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            plotLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            plotLabel.bottomAnchor.constraint(lessThanOrEqualTo: still.bottomAnchor),
            countdownLabel.topAnchor.constraint(equalTo: still.bottomAnchor, constant: 22),
            countdownLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            countdownLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            countdownLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, plot: String, image: String) {
        titleLabel.text = title
        plotLabel.text = plot
        still.isHidden = image.isEmpty
        if !image.isEmpty { PlayerImageLoader.shared.load(image, into: still) }
    }

    func setCountdown(seconds: Int) {
        countdownLabel.text = "Playing in \(seconds)s   ·   Select to play now   ·   Menu to stay"
    }
}

// MARK: - Pills

/// Label with padding and a rounded translucent background, for short notices.
final class PillLabel: UILabel {
    var insets = UIEdgeInsets(top: 14, left: 28, bottom: 14, right: 28)
    var fillColor: UIColor = PlayerStyle.panel.withAlphaComponent(0.85) { didSet { backgroundColor = fillColor } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textColor = .white
        font = .systemFont(ofSize: 26, weight: .medium)
        textAlignment = .center
        numberOfLines = 0
        backgroundColor = fillColor
        layer.cornerRadius = PlayerStyle.cornerRadius
        layer.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

// MARK: - Episode strip

struct EpisodeCardModel {
    let label: String      // "S1 E4"
    let title: String
    let image: String
    let progress: Double   // 0...1 watched fraction, for the thin bar under the still
}

/// Horizontal row of episode cards shown from the top edge. The remote moves a cursor
/// (not the focus engine, which the player deliberately keeps for itself) and Select
/// plays the highlighted episode.
final class EpisodeStripView: UIView {
    private let gradient = CAGradientLayer()
    private let heading = UILabel()
    private let scroll = UIScrollView()
    private var cards: [EpisodeCard] = []
    private(set) var selectedIndex = 0
    private var currentIndex = 0
    private let cardWidth: CGFloat = 320
    private let cardGap: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [PlayerStyle.panel.withAlphaComponent(0.94).cgColor, PlayerStyle.panel.withAlphaComponent(0).cgColor]
        layer.addSublayer(gradient)
        heading.textColor = .white
        heading.font = .systemFont(ofSize: 28, weight: .semibold)
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        [heading, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PlayerStyle.sideMargin),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PlayerStyle.sideMargin),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PlayerStyle.sideMargin),
            scroll.heightAnchor.constraint(equalToConstant: 290),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        for (i, card) in cards.enumerated() {
            card.frame = CGRect(x: CGFloat(i) * (cardWidth + cardGap), y: 0, width: cardWidth, height: 290)
        }
        scroll.contentSize = CGSize(width: CGFloat(cards.count) * (cardWidth + cardGap) - cardGap, height: 290)
        scrollToSelection(animated: false)
    }

    func configure(heading text: String, episodes: [EpisodeCardModel], current: Int) {
        heading.text = text
        cards.forEach { $0.removeFromSuperview() }
        cards = episodes.map { model in
            let card = EpisodeCard()
            card.configure(model)
            scroll.addSubview(card)
            return card
        }
        currentIndex = current
        selectedIndex = current
        refreshHighlight()
        setNeedsLayout()
    }

    /// Move the cursor; returns false when already at the edge so the caller can ignore the press.
    @discardableResult
    func move(by delta: Int) -> Bool {
        let target = selectedIndex + delta
        guard cards.indices.contains(target) else { return false }
        selectedIndex = target
        refreshHighlight()
        scrollToSelection(animated: true)
        return true
    }

    private func refreshHighlight() {
        for (i, card) in cards.enumerated() {
            card.setState(selected: i == selectedIndex, playing: i == currentIndex)
        }
    }

    private func scrollToSelection(animated: Bool) {
        guard cards.indices.contains(selectedIndex), scroll.bounds.width > 0 else { return }
        let cardX = CGFloat(selectedIndex) * (cardWidth + cardGap)
        var x = cardX - (scroll.bounds.width - cardWidth) / 2
        x = max(0, min(x, max(0, scroll.contentSize.width - scroll.bounds.width)))
        scroll.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }
}

private final class EpisodeCard: UIView {
    private let still = UIImageView()
    private let label = UILabel()
    private let titleLabel = UILabel()
    private let progress = UIView()
    private let progressTrack = UIView()
    private let nowBadge = PillLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        still.contentMode = .scaleAspectFill
        still.layer.cornerRadius = 10
        still.layer.masksToBounds = true
        still.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        still.layer.borderColor = PlayerStyle.accent.cgColor
        label.textColor = PlayerStyle.accent
        label.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 22, weight: .medium)
        titleLabel.numberOfLines = 2
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        progress.backgroundColor = PlayerStyle.accent
        nowBadge.text = "NOW PLAYING"
        nowBadge.font = .systemFont(ofSize: 15, weight: .bold)
        nowBadge.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        nowBadge.fillColor = PlayerStyle.accent.withAlphaComponent(0.9)
        nowBadge.textColor = PlayerStyle.panel
        [still, progressTrack, progress, label, titleLabel, nowBadge].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        still.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 180)
        progressTrack.frame = CGRect(x: 0, y: 174, width: bounds.width, height: 6)
        progress.frame = CGRect(x: 0, y: 174, width: progressTrack.bounds.width * progressWidth, height: 6)
        label.frame = CGRect(x: 0, y: 190, width: bounds.width, height: 26)
        titleLabel.frame = CGRect(x: 0, y: 218, width: bounds.width, height: 60)
        nowBadge.sizeToFit()
        nowBadge.frame.origin = CGPoint(x: 12, y: 12)
    }

    private var progressWidth: CGFloat = 0

    func configure(_ model: EpisodeCardModel) {
        label.text = model.label
        titleLabel.text = model.title
        progressWidth = CGFloat(min(1, max(0, model.progress)))
        progressTrack.isHidden = model.progress <= 0
        progress.isHidden = model.progress <= 0
        if !model.image.isEmpty { PlayerImageLoader.shared.load(model.image, into: still) }
    }

    func setState(selected: Bool, playing: Bool) {
        still.layer.borderWidth = selected ? 5 : 0
        transform = selected ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        alpha = selected ? 1 : 0.8
        nowBadge.isHidden = !playing
    }
}

// MARK: - Track menu

/// Two-column picker: subtitles on the left (with Off), audio on the right. Left/right
/// switch columns, up/down move within one, Select applies the highlighted row.
final class TrackMenuView: UIView {
    enum Column { case subtitles, audio }
    struct Choice { let column: Column; let row: Int }

    private let subtitleColumn = TrackColumn(title: "Subtitles")
    private let audioColumn = TrackColumn(title: "Audio")
    private(set) var column: Column = .subtitles
    private var subtitleRow = 0
    private var audioRow = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = PlayerStyle.panel.withAlphaComponent(0.94)
        layer.cornerRadius = PlayerStyle.cornerRadius
        layer.masksToBounds = true
        [subtitleColumn, audioColumn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            subtitleColumn.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            subtitleColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            subtitleColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -30),
            subtitleColumn.widthAnchor.constraint(equalToConstant: 360),
            audioColumn.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            audioColumn.leadingAnchor.constraint(equalTo: subtitleColumn.trailingAnchor, constant: 40),
            audioColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
            audioColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -30),
            audioColumn.widthAnchor.constraint(equalToConstant: 360),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `subtitles` excludes Off; the view adds it as row 0. Selected rows use the same numbering.
    func configure(subtitles: [String], selectedSubtitle: Int?, audio: [String], selectedAudio: Int?) {
        subtitleColumn.rows = ["Off"] + subtitles
        subtitleColumn.checkedRow = selectedSubtitle.map { $0 + 1 } ?? 0
        audioColumn.rows = audio.isEmpty ? ["Default"] : audio
        audioColumn.checkedRow = audio.isEmpty ? 0 : (selectedAudio ?? 0)
        subtitleRow = subtitleColumn.checkedRow
        audioRow = audioColumn.checkedRow
        column = .subtitles
        refresh()
    }

    func moveRow(by delta: Int) {
        switch column {
        case .subtitles: subtitleRow = clamp(subtitleRow + delta, count: subtitleColumn.rows.count)
        case .audio: audioRow = clamp(audioRow + delta, count: audioColumn.rows.count)
        }
        refresh()
    }

    func switchColumn(to target: Column) {
        column = target
        refresh()
    }

    /// The highlighted row; subtitles row 0 means Off, row n means subtitle n-1.
    func highlighted() -> Choice {
        Choice(column: column, row: column == .subtitles ? subtitleRow : audioRow)
    }

    func markChecked(_ choice: Choice) {
        switch choice.column {
        case .subtitles: subtitleColumn.checkedRow = choice.row
        case .audio: audioColumn.checkedRow = choice.row
        }
        refresh()
    }

    private func clamp(_ value: Int, count: Int) -> Int { max(0, min(count - 1, value)) }

    private func refresh() {
        subtitleColumn.highlightRow = column == .subtitles ? subtitleRow : nil
        audioColumn.highlightRow = column == .audio ? audioRow : nil
    }
}

private final class TrackColumn: UIView {
    private let heading = UILabel()
    private let stack = UIStackView()
    var rows: [String] = [] { didSet { rebuild() } }
    var checkedRow = 0 { didSet { restyle() } }
    var highlightRow: Int? { didSet { restyle() } }

    init(title: String) {
        super.init(frame: .zero)
        heading.text = title.uppercased()
        heading.textColor = PlayerStyle.accent
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        stack.axis = .vertical
        stack.spacing = 6
        [heading, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for text in rows {
            let row = PillLabel()
            row.text = text
            row.textAlignment = .left
            row.font = .systemFont(ofSize: 24, weight: .medium)
            row.insets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
            row.layer.cornerRadius = 10
            stack.addArrangedSubview(row)
        }
        restyle()
    }

    private func restyle() {
        for (i, view) in stack.arrangedSubviews.enumerated() {
            guard let row = view as? PillLabel, i < rows.count else { continue }
            let checked = i == checkedRow
            let highlighted = i == highlightRow
            row.text = (checked ? "✓  " : "    ") + rows[i]
            row.fillColor = highlighted ? PlayerStyle.accent : .clear
            row.textColor = highlighted ? PlayerStyle.panel : (checked ? .white : PlayerStyle.dimText)
        }
    }
}
