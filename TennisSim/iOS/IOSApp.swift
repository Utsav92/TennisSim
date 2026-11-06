import UIKit
import MetalKit

@main
final class IOSAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = IOSSceneDelegate.self
        return c
    }
}

final class IOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: ws)
        window?.rootViewController = GameViewController()
        window?.makeKeyAndVisible()
    }
}

/// iPhone/iPad front end: left half of the screen is a floating joystick, buttons for swing / camera / menu.
final class GameViewController: UIViewController {
    private var renderer: Renderer!
    private let game = GameState()
    private let input = InputManager()
    private let hud = UILabel()
    private var moveTouch: UITouch?
    private var moveOrigin = CGPoint.zero
    private let stick = UIView()
    private let audio = GameAudio()
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private var controlViews: [UIView] = []          // on-screen gameplay controls (hidden on the home screen)
    private var overlay: UIView?                      // home or pause screen currently shown

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func loadView() {
        let v = MTKView(frame: .zero)
        v.preferredFramesPerSecond = 120
        v.isMultipleTouchEnabled = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let mtk = view as? MTKView, let r = Renderer(view: mtk, game: game, input: input) else {
            NSLog("Metal initialisation failed"); return
        }
        renderer = r
        game.difficulty = SettingsStore.difficulty
        CourtSurface.current = SettingsStore.courtSurface
        renderer.cameraMode = SettingsStore.followCamera ? .follow : .broadcast
        renderer.showStats = SettingsStore.showStats
        audio.muted = !SettingsStore.sound
        renderer.onGameEvent = { [weak self] e in
            self?.audio.handle(e)
            if case .hit(_, let speed, _, _, _) = e { self?.haptic.impactOccurred(intensity: CGFloat(min(1, max(0.3, (speed - 50) / 120)))) }
        }
        renderer.onAnnouncement = { [weak self] t in self?.audio.speak(t) }
        renderer.onCrowdLevel = { [weak self] l in self?.audio.setCrowd(level: l) }

        hud.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hud.textColor = .white; hud.numberOfLines = 0
        hud.shadowColor = .black; hud.shadowOffset = CGSize(width: 1, height: 1)
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                                     hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4)])
        renderer.onHUD = { [weak self] s in self?.hud.text = s }

        func button(_ title: String, size: CGFloat, action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal); b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 15)
            b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            b.layer.cornerRadius = size / 2
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: size).isActive = true
            b.heightAnchor.constraint(equalToConstant: size).isActive = true
            b.addTarget(self, action: action, for: .touchDown)
            view.addSubview(b)
            return b
        }
        let swing = button("SWING", size: 96, action: #selector(swingTapped))
        let slice = button("SLICE", size: 56, action: #selector(sliceTapped))
        let lob = button("LOB", size: 56, action: #selector(lobTapped))
        let drop = button("DROP", size: 56, action: #selector(dropTapped))
        for b in [slice, lob, drop] { b.titleLabel?.font = .boldSystemFont(ofSize: 12) }
        let menu = button("☰", size: 44, action: #selector(menuTapped))
        NSLayoutConstraint.activate([
            swing.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            swing.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            slice.trailingAnchor.constraint(equalTo: swing.leadingAnchor, constant: -12), slice.bottomAnchor.constraint(equalTo: swing.bottomAnchor),
            lob.trailingAnchor.constraint(equalTo: swing.trailingAnchor), lob.bottomAnchor.constraint(equalTo: swing.topAnchor, constant: -12),
            drop.trailingAnchor.constraint(equalTo: lob.leadingAnchor, constant: -12), drop.bottomAnchor.constraint(equalTo: lob.bottomAnchor),
            menu.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            menu.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)])
        stick.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        stick.layer.cornerRadius = 45; stick.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        stick.isHidden = true; stick.isUserInteractionEnabled = false
        view.addSubview(stick)
        input.onMenu = { [weak self] in DispatchQueue.main.async { self?.menuTapped() } }
        controlViews = [swing, slice, lob, drop, menu, hud]
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.overlay == nil { self?.menuTapped() }                      // backgrounding pauses the match
        }
        showHome()
    }

    // MARK: Home + pause screens

    private func setOverlay(_ v: UIView?) {
        overlay?.removeFromSuperview(); overlay = v
        guard let v else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        v.alpha = 0; UIView.animate(withDuration: 0.2) { v.alpha = 1 }
    }

    private func apply(option: String, _ on: Bool) {
        switch option {
        case "sound": audio.muted = !on; SettingsStore.sound = on
        case "camera": renderer.cameraMode = on ? .follow : .broadcast; SettingsStore.followCamera = on
        case "stats": renderer.showStats = on; SettingsStore.showStats = on; hud.isHidden = !on
        default: break
        }
    }
    private func apply(difficulty d: Difficulty) { game.difficulty = d; SettingsStore.difficulty = d }

    private func showHome() {
        game.paused = true
        for v in controlViews { v.isHidden = true }
        let home = HomeMenuView()
        home.onCourtChanged = { s in CourtSurface.current = s; SettingsStore.courtSurface = s }      // the court behind the menu updates live
        home.onDifficulty = { [weak self] d in self?.apply(difficulty: d) }
        home.onOption = { [weak self] k, v in self?.apply(option: k, v) }
        home.onPlay = { [weak self] in
            guard let self else { return }
            game.newMatch(); setOverlay(nil)
            for v in controlViews { v.isHidden = false }
            hud.isHidden = !renderer.showStats
            game.paused = false
        }
        setOverlay(home)
        if ProcessInfo.processInfo.environment["TS_AUTOPLAY"] != nil { home.onPlay?() }       // test hook: skip the home screen
    }

    private func showPause() {
        game.paused = true
        let p = PauseMenuView(score: game.scoreText.replacingOccurrences(of: "\n", with: "  ·  "))
        p.onResume = { [weak self] in self?.setOverlay(nil); self?.game.paused = false }
        p.onRestart = { [weak self] in self?.game.newMatch(); self?.setOverlay(nil); self?.game.paused = false }
        p.onQuit = { [weak self] in self?.game.newMatch(); self?.showHome() }
        p.onDifficulty = { [weak self] d in self?.apply(difficulty: d) }
        p.onOption = { [weak self] k, v in self?.apply(option: k, v) }
        setOverlay(p)
    }

    @objc private func swingTapped() { input.touchSwing(.topspin) }
    @objc private func sliceTapped() { input.touchSwing(.slice) }
    @objc private func lobTapped() { input.touchSwing(.lob) }
    @objc private func dropTapped() { input.touchSwing(.drop) }

    @objc private func menuTapped() { if overlay == nil { showPause() } }

    // MARK: Floating joystick on the left half of the screen
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where overlay == nil && moveTouch == nil && t.location(in: view).x < view.bounds.midX {
            moveTouch = t; moveOrigin = t.location(in: view)
            stick.center = moveOrigin; stick.isHidden = false
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = moveTouch, touches.contains(t) else { return }
        let p = t.location(in: view)
        var v = SIMD2<Float>(Float(p.x - moveOrigin.x), Float(moveOrigin.y - p.y)) / 60      // up on screen = toward the net
        if simd_length(v) > 1 { v = simd_normalize(v) }
        input.setTouchMove(v)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endMove(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endMove(touches) }
    private func endMove(_ touches: Set<UITouch>) {
        guard let t = moveTouch, touches.contains(t) else { return }
        moveTouch = nil; stick.isHidden = true; input.setTouchMove(.zero)
    }
}
