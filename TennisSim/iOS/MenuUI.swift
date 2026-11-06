import UIKit

/// Shared look for the home and pause screens.
enum MenuStyle {
    static let accent = UIColor(red: 0.80, green: 0.93, blue: 0.20, alpha: 1)        // tennis-ball yellow-green
    static let panel = UIColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 0.82)

    static func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> UIButton {
        var cfg = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        cfg.title = title
        cfg.baseBackgroundColor = primary ? accent : UIColor.white
        cfg.baseForegroundColor = primary ? UIColor(red: 0.05, green: 0.10, blue: 0.05, alpha: 1) : .white
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: primary ? 14 : 11, leading: 28, bottom: primary ? 14 : 11, trailing: 28)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { c in
            var c = c; c.font = .systemFont(ofSize: primary ? 20 : 16, weight: .heavy); return c }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.setContentCompressionResistancePriority(.required, for: .vertical)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: primary ? 220 : 180).isActive = true
        return b
    }

    static func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white, spacing: CGFloat = 0) -> UILabel {
        let l = UILabel()
        l.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                                         .foregroundColor: color, .kern: spacing])
        l.textAlignment = .center; l.numberOfLines = 0
        return l
    }

    static func sectionTitle(_ t: String) -> UILabel { label(t.uppercased(), size: 11, weight: .bold, color: UIColor.white.withAlphaComponent(0.6), spacing: 2) }
}

/// Court selection card: a coloured swatch with mini court lines, name and one-line description.
final class CourtCard: UIControl {
    let surface: CourtSurface
    private let border = CALayer()

    init(surface: CourtSurface) {
        self.surface = surface
        super.init(frame: .zero)
        layer.cornerRadius = 14; clipsToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        let swatch = CourtSwatch(surface: surface)
        swatch.isUserInteractionEnabled = false
        let name = MenuStyle.label(surface.name, size: 15, weight: .bold)
        let blurb = MenuStyle.label(surface.blurb, size: 10, color: UIColor.white.withAlphaComponent(0.7))
        let stack = UIStackView(arrangedSubviews: [swatch, name, blurb])
        stack.axis = .vertical; stack.spacing = 4; stack.alignment = .fill; stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            swatch.heightAnchor.constraint(equalToConstant: 46), widthAnchor.constraint(equalToConstant: 160)])
        layer.borderWidth = 2; layer.borderColor = UIColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet {
            layer.borderColor = (isSelected ? MenuStyle.accent : UIColor.clear).cgColor
            backgroundColor = UIColor.white.withAlphaComponent(isSelected ? 0.18 : 0.08)
        }
    }
}

private final class CourtSwatch: UIView {
    let surface: CourtSurface
    init(surface: CourtSurface) { self.surface = surface; super.init(frame: .zero); layer.cornerRadius = 8; clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    private func ui(_ c: SIMD4<Float>) -> UIColor { UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1) }
    override func draw(_ rect: CGRect) {
        ui(surface.surroundColor).setFill(); UIRectFill(rect)
        let c = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        ui(surface.courtColor).setFill(); UIRectFill(c)
        if surface == .grass {                              // mowing stripes
            UIColor.white.withAlphaComponent(0.07).setFill()
            var x = c.minX; while x < c.maxX { UIRectFillUsingBlendMode(CGRect(x: x, y: c.minY, width: c.width / 12, height: c.height), .normal); x += c.width / 6 }
        }
        UIColor.white.withAlphaComponent(0.9).setStroke()
        let p = UIBezierPath(rect: c); p.lineWidth = 1.5; p.stroke()
        let mid = UIBezierPath(); mid.move(to: CGPoint(x: c.midX, y: c.minY)); mid.addLine(to: CGPoint(x: c.midX, y: c.maxY)); mid.lineWidth = 2; mid.stroke()
        let sv = UIBezierPath(); sv.move(to: CGPoint(x: c.minX + c.width * 0.2, y: c.midY)); sv.addLine(to: CGPoint(x: c.maxX - c.width * 0.2, y: c.midY))
        sv.move(to: CGPoint(x: c.minX + c.width * 0.2, y: c.minY)); sv.addLine(to: CGPoint(x: c.minX + c.width * 0.2, y: c.maxY))
        sv.move(to: CGPoint(x: c.maxX - c.width * 0.2, y: c.minY)); sv.addLine(to: CGPoint(x: c.maxX - c.width * 0.2, y: c.maxY))
        sv.lineWidth = 1; sv.stroke()
    }
}

/// Segmented choice row used for difficulty etc.
func makeSegment(_ items: [String], selected: Int, onChange: @escaping (Int) -> Void) -> UISegmentedControl {
    let s = UISegmentedControl(items: items)
    s.selectedSegmentIndex = selected
    s.selectedSegmentTintColor = MenuStyle.accent
    s.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .normal)
    s.setTitleTextAttributes([.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .selected)
    s.addAction(UIAction { [unowned s] _ in onChange(s.selectedSegmentIndex) }, for: .valueChanged)
    return s
}

func makeToggleRow(_ title: String, on: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
    let l = MenuStyle.label(title, size: 15, weight: .semibold); l.textAlignment = .left
    let sw = UISwitch(); sw.isOn = on; sw.onTintColor = MenuStyle.accent
    sw.addAction(UIAction { [unowned sw] _ in onChange(sw.isOn) }, for: .valueChanged)
    let row = UIStackView(arrangedSubviews: [l, sw]); row.axis = .horizontal; row.spacing = 16; row.alignment = .center
    return row
}

/// Front screen shown before a match: title, court selection, difficulty, options, PLAY.
final class HomeMenuView: UIView {
    var onPlay: (() -> Void)?
    var onCourtChanged: ((CourtSurface) -> Void)?
    var onDifficulty: ((Difficulty) -> Void)?
    var onOption: ((String, Bool) -> Void)?
    private var cards: [CourtCard] = []

    init() {
        super.init(frame: .zero)
        let dim = CAGradientLayer()
        dim.colors = [UIColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.88).cgColor, UIColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.45).cgColor,
                      UIColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.88).cgColor]
        layer.addSublayer(dim); gradient = dim

        let title = MenuStyle.label("TENNISSIM", size: 34, weight: .black, spacing: 7)
        let sub = MenuStyle.label("PICK YOUR SURFACE", size: 12, weight: .bold, color: MenuStyle.accent, spacing: 4)
        let courtRow = UIStackView(); courtRow.axis = .horizontal; courtRow.spacing = 14
        for s in CourtSurface.allCases {
            let c = CourtCard(surface: s); c.isSelected = (s == CourtSurface.current)
            c.addAction(UIAction { [weak self] _ in self?.select(s) }, for: .touchUpInside)
            cards.append(c); courtRow.addArrangedSubview(c)
        }
        let diff = makeSegment(Difficulty.allCases.map { $0.name }, selected: SettingsStore.difficulty.rawValue) { [weak self] i in
            if let d = Difficulty(rawValue: i) { self?.onDifficulty?(d) } }
        diff.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let play = MenuStyle.button("PLAY", primary: true) { [weak self] in self?.onPlay?() }

        let opts = UIStackView(arrangedSubviews: [
            makeToggleRow("Sound", on: SettingsStore.sound) { [weak self] v in self?.onOption?("sound", v) },
            makeToggleRow("Follow camera", on: SettingsStore.followCamera) { [weak self] v in self?.onOption?("camera", v) }])
        opts.axis = .horizontal; opts.spacing = 28

        let stack = UIStackView(arrangedSubviews: [title, sub, courtRow, MenuStyle.sectionTitle("Opponent"), diff, opts, play])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 10
        stack.setCustomSpacing(2, after: title); stack.setCustomSpacing(10, after: sub); stack.setCustomSpacing(14, after: courtRow)
        stack.setCustomSpacing(10, after: opts)
        let scroll = UIScrollView(); scroll.showsVerticalScrollIndicator = false; scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor)])
        stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    private var gradient: CAGradientLayer?
    override func layoutSubviews() { super.layoutSubviews(); gradient?.frame = bounds }

    private func select(_ s: CourtSurface) {
        for c in cards { c.isSelected = (c.surface == s) }
        UISelectionFeedbackGenerator().selectionChanged()
        onCourtChanged?(s)
    }
}

/// In-game pause screen: resume, restart, quick settings, quit to the home screen.
final class PauseMenuView: UIView {
    var onResume: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDifficulty: ((Difficulty) -> Void)?
    var onOption: ((String, Bool) -> Void)?

    init(score: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        let panel = UIView(); panel.backgroundColor = MenuStyle.panel; panel.layer.cornerRadius = 22
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let title = MenuStyle.label("PAUSED", size: 30, weight: .black, spacing: 6)
        let sc = MenuStyle.label(score, size: 13, color: UIColor.white.withAlphaComponent(0.7))
        let resume = MenuStyle.button("RESUME", primary: true) { [weak self] in self?.onResume?() }
        let restart = MenuStyle.button("Restart match") { [weak self] in self?.onRestart?() }
        let quit = MenuStyle.button("Quit to home") { [weak self] in self?.onQuit?() }
        let diff = makeSegment(Difficulty.allCases.map { $0.name }, selected: SettingsStore.difficulty.rawValue) { [weak self] i in
            if let d = Difficulty(rawValue: i) { self?.onDifficulty?(d) } }
        let toggles = UIStackView(arrangedSubviews: [
            makeToggleRow("Sound", on: SettingsStore.sound) { [weak self] v in self?.onOption?("sound", v) },
            makeToggleRow("Follow cam", on: SettingsStore.followCamera) { [weak self] v in self?.onOption?("camera", v) },
            makeToggleRow("Stats", on: SettingsStore.showStats) { [weak self] v in self?.onOption?("stats", v) }])
        toggles.axis = .vertical; toggles.spacing = 10

        let left = UIStackView(arrangedSubviews: [title, sc, resume, restart, quit]); left.axis = .vertical; left.spacing = 12; left.alignment = .center
        left.setCustomSpacing(2, after: title); left.setCustomSpacing(16, after: sc)
        let right = UIStackView(arrangedSubviews: [MenuStyle.sectionTitle("Opponent"), diff, MenuStyle.sectionTitle("Options"), toggles])
        right.axis = .vertical; right.spacing = 10; right.alignment = .fill
        let row = UIStackView(arrangedSubviews: [left, right]); row.axis = .horizontal; row.spacing = 36; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor), panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24), row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 32), row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -32),
            right.widthAnchor.constraint(equalToConstant: 280)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
