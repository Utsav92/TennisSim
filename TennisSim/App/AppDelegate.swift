import AppKit
import MetalKit

final class GameView: MTKView {
    var input: InputManager!
    var onCameraToggle: (() -> Void)?
    var onMenuToggle: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, !e.isARepeat { onMenuToggle?(); return }          // Esc
        if e.keyCode == 8, !e.isARepeat { onCameraToggle?() }                  // C
        input.keyDown(e.keyCode, isRepeat: e.isARepeat)
    }
    override func keyUp(with e: NSEvent) { input.keyUp(e.keyCode) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: GameView!
    var renderer: Renderer!
    let input = InputManager()
    let game = GameState()
    let hud = NSTextField(labelWithString: "")
    var menu: NSVisualEffectView!
    var difficultyControl: NSSegmentedControl!
    var cameraControl: NSSegmentedControl!
    var statsCheck: NSButton!
    var scaleControl: NSSegmentedControl!
    var soundCheck: NSButton!
    let audio = GameAudio()

    func applicationDidFinishLaunching(_ n: Notification) {
        view = GameView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.input = input
        guard let r = Renderer(view: view, game: game, input: input) else {
            NSLog("Metal initialisation failed"); NSApp.terminate(nil); return
        }
        renderer = r
        game.difficulty = SettingsStore.difficulty
        renderer.cameraMode = SettingsStore.followCamera ? .follow : .broadcast
        renderer.showStats = SettingsStore.showStats
        renderer.renderScale = SettingsStore.renderScale
        audio.muted = !SettingsStore.sound
        renderer.onGameEvent = { [weak self] e in self?.audio.handle(e) }
        renderer.onAnnouncement = { [weak self] text in self?.audio.speak(text) }
        renderer.onCrowdLevel = { [weak self] level in self?.audio.setCrowd(level: level) }
        view.onCameraToggle = { [unowned self] in setCamera(follow: renderer.cameraMode == .broadcast) }
        view.onMenuToggle = { [unowned self] in toggleMenu() }
        input.onMenu = { [unowned self] in DispatchQueue.main.async { toggleMenu() } }

        hud.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        hud.textColor = .white
        hud.maximumNumberOfLines = 0
        hud.frame = NSRect(x: 12, y: 8, width: 1000, height: 100)
        hud.autoresizingMask = [.maxXMargin, .maxYMargin]
        hud.shadow = { let s = NSShadow(); s.shadowColor = .black; s.shadowBlurRadius = 3; return s }()
        view.addSubview(hud)
        renderer.onHUD = { [weak self] s in self?.hud.stringValue = s }
        buildMenu()

        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "TennisSim"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Settings menu

    private func setCamera(follow: Bool) {
        renderer.cameraMode = follow ? .follow : .broadcast
        SettingsStore.followCamera = follow
        cameraControl?.selectedSegment = follow ? 1 : 0
    }

    private func buildMenu() {
        let w: CGFloat = 380, h: CGFloat = 372
        menu = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        menu.material = .hudWindow; menu.blendingMode = .withinWindow; menu.state = .active
        menu.wantsLayer = true; menu.layer?.cornerRadius = 14
        menu.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        func label(_ t: String, y: CGFloat, size: CGFloat = 13, bold: Bool = false) {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
            l.frame = NSRect(x: 24, y: y, width: w - 48, height: 20); menu.addSubview(l)
        }
        label("Paused", y: h - 40, size: 20, bold: true)
        label("Opponent difficulty", y: h - 80)
        difficultyControl = NSSegmentedControl(labels: Difficulty.allCases.map(\.name), trackingMode: .selectOne,
                                               target: self, action: #selector(difficultyChanged))
        difficultyControl.frame = NSRect(x: 24, y: h - 110, width: w - 48, height: 26)
        difficultyControl.selectedSegment = game.difficulty.rawValue
        menu.addSubview(difficultyControl)
        label("Camera", y: h - 145)
        cameraControl = NSSegmentedControl(labels: ["Broadcast", "Follow"], trackingMode: .selectOne,
                                           target: self, action: #selector(cameraChanged))
        cameraControl.frame = NSRect(x: 24, y: h - 175, width: w - 48, height: 26)
        cameraControl.selectedSegment = renderer.cameraMode == .follow ? 1 : 0
        menu.addSubview(cameraControl)
        label(renderer.backend != nil ? "Render resolution (MetalFX upscaling)" : "Render resolution (needs Metal 4)", y: h - 210)
        scaleControl = NSSegmentedControl(labels: ["Native", "75%", "50%"], trackingMode: .selectOne, target: self, action: #selector(scaleChanged))
        scaleControl.frame = NSRect(x: 24, y: h - 240, width: w - 48, height: 26)
        scaleControl.selectedSegment = renderer.renderScale >= 0.99 ? 0 : (renderer.renderScale >= 0.7 ? 1 : 2)
        scaleControl.isEnabled = renderer.backend != nil
        menu.addSubview(scaleControl)
        statsCheck = NSButton(checkboxWithTitle: "Show performance stats", target: self, action: #selector(statsChanged))
        statsCheck.state = renderer.showStats ? .on : .off
        statsCheck.frame = NSRect(x: 24, y: h - 272, width: w - 48, height: 22); menu.addSubview(statsCheck)
        soundCheck = NSButton(checkboxWithTitle: "Sound (crowd, ball, umpire)", target: self, action: #selector(soundChanged))
        soundCheck.state = audio.muted ? .off : .on
        soundCheck.frame = NSRect(x: 24, y: h - 300, width: w - 48, height: 22); menu.addSubview(soundCheck)
        let resume = NSButton(title: "Resume (Esc)", target: self, action: #selector(resumeClicked))
        resume.frame = NSRect(x: 24, y: 16, width: 160, height: 30); resume.bezelStyle = .rounded; resume.keyEquivalent = "\r"
        menu.addSubview(resume)
        let again = NSButton(title: "New match", target: self, action: #selector(newMatchClicked))
        again.frame = NSRect(x: w - 24 - 160, y: 16, width: 160, height: 30); again.bezelStyle = .rounded
        menu.addSubview(again)
        menu.isHidden = true
        menu.frame.origin = NSPoint(x: (view.bounds.width - w) / 2, y: (view.bounds.height - h) / 2)
        view.addSubview(menu)
    }

    private func toggleMenu() {
        game.paused.toggle()
        menu.isHidden = !game.paused
        if !game.paused { window.makeFirstResponder(view) }
    }
    @objc private func difficultyChanged() {
        game.difficulty = Difficulty(rawValue: difficultyControl.selectedSegment) ?? .medium
        SettingsStore.difficulty = game.difficulty
    }
    @objc private func cameraChanged() { setCamera(follow: cameraControl.selectedSegment == 1) }
    @objc private func scaleChanged() {
        renderer.renderScale = [1.0, 0.75, 0.5][scaleControl.selectedSegment]
        SettingsStore.renderScale = renderer.renderScale
    }
    @objc private func soundChanged() { audio.muted = soundCheck.state != .on; SettingsStore.sound = !audio.muted }
    @objc private func statsChanged() { renderer.showStats = statsCheck.state == .on; SettingsStore.showStats = renderer.showStats }
    @objc private func resumeClicked() { toggleMenu() }
    @objc private func newMatchClicked() { game.newMatch(); toggleMenu() }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
