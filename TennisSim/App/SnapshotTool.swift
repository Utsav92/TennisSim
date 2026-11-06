import AppKit
import MetalKit

/// `TennisSim --snapshot out.png`: renders one frame offscreen for visual verification.
enum SnapshotTool {
    static func run(path: String) -> Int32 {
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let game = GameState()
        guard let r = Renderer(view: view, game: game, input: InputManager()) else { print("Metal init failed"); return 1 }
        // Mid-rally pose: ball in flight, player mid-swing.
        game.player.position = float3(1.5, 0, 11.4)
        game.player.swingTime = 0.12; game.player.swingLift = 0.4
        game.phase = .rally
        game.lastHitter = 1
        game.opponent.position = float3(-1.0, 0, -11.5)
        game.opponent.swingTime = 0.1
        game.ball.position = float3(2.2, 1.4, 4)
        game.ball.velocity = float3(0, 2, -15)
        for _ in 0..<300 { r.camera.update(mode: .broadcast, player: game.player, ball: game.ball, dt: 1 / 60) }
        let ok = r.snapshot(to: path)
        print(ok ? "wrote \(path)" : "snapshot failed")
        return ok ? 0 : 1
    }

    static func bench(frames: Int) -> Int32 {
        func stat(_ a: [Double]) -> String {
            let s = a.sorted(); let avg = a.reduce(0, +) / Double(max(a.count, 1))
            return String(format: "avg %.2f  p95 %.2f  max %.2f ms", avg, s[Int(Double(s.count) * 0.95)], s.last ?? 0)
        }
        for classic in [false, true] {
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let game = GameState()
            guard let r = Renderer(view: view, game: game, input: InputManager(), forceClassic: classic) else { print("Metal init failed"); return 1 }
            game.phase = .rally; game.lastHitter = 1; game.ball.position = float3(0, 1.4, 4)
            print("== \(r.backendName) backend (\(classic ? "forced classic" : "default")) on \(r.device.name)")
            for (w, h) in [(1280, 720), (2560, 1440), (3840, 2160)] {
                let res = r.benchmark(frames: frames, width: w, height: h)
                print("\(w)x\(h) \(r.backend != nil ? "MetalFX TAA @ \(Int(r.effectiveScale * 100))% render scale" : "4xMSAA") + \(Renderer.shadowSize)² shadow map | draws=\(res.draws) tris=\(res.tris)")
                print("   GPU (backend-reported): \(stat(res.gpuMs))")
                print("   wall submit→done:      \(stat(res.wallMs))")
                print(String(format: "   pipelined throughput:  %.3f ms/frame (%.0f fps ceiling)", r.throughput(frames: frames * 3, width: w, height: h), 1000 / r.throughput(frames: frames * 3, width: w, height: h)))
                print("   CPU encode+submit: \(stat(res.cpuMs))")
            }
        }
        return 0
    }

    /// `--compare-backends`: renders the same frame with the Metal 4 + MetalFX path and the classic path and reports how they differ.
    static func compareBackends() -> Int32 {
        func pixels(_ img: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &out, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return out
        }
        var imgs: [CGImage] = []
        for classic in [false, true] {
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let game = GameState()
            guard let r = Renderer(view: view, game: game, input: InputManager(), forceClassic: classic) else { return 1 }
            game.phase = .rally; game.lastHitter = 1
            game.player.position = float3(1.5, 0, 11.4); game.opponent.position = float3(-1, 0, -11.5)
            game.ball.position = float3(2.2, 1.4, 4)
            for _ in 0..<300 { r.camera.update(mode: .broadcast, player: game.player, ball: game.ball, dt: 1 / 60) }
            print("backend: \(r.backendName)")
            guard let img = r.snapshotImage() else { return 1 }
            imgs.append(img)
        }
        let a = pixels(imgs[0]), b = pixels(imgs[1])
        var sum = 0, maxD = 0, differing = 0
        for i in 0..<a.count where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i])); sum += d; maxD = max(maxD, d); if d > 2 { differing += 1 }
        }
        print(String(format: "classic vs Metal 4+MetalFX (differ by design: HDR, bloom, TAA, grading): mean diff %.2f / 255, max %d, channels >2: %d of %d",
                     Double(sum) / Double(a.count * 3 / 4), maxD, differing, a.count * 3 / 4))
        return 0
    }

    /// `--poses out.png`: 4×2 contact sheet of the rig (idle, run, forehand, backhand, serve) and a numeric check that the
    /// animated racket head matches the gameplay hit point at contact.
    static func poses(path: String) -> Int32 {
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let game = GameState()
        guard let r = Renderer(view: view, game: game, input: InputManager()) else { return 1 }
        game.phase = .rally; game.lastHitter = 1
        game.ball.position = float3(0, -5, 0)                      // hide the ball under the court
        game.opponent.position = float3(0, 0, -30)
        let w = 640, h = 480
        enum Pose { case idle, run, swing(Float, SwingKind) }
        let list: [(String, Pose)] = [("idle", .idle), ("run", .run), ("forehand 0.28", .swing(0.28, .forehand)), ("forehand 0.45", .swing(0.45, .forehand)),
                                      ("backhand 0.28", .swing(0.28, .backhand)), ("backhand 0.45", .swing(0.45, .backhand)),
                                      ("backhand 0.70", .swing(0.70, .backhand)), ("serve 0.50", .swing(0.50, .overhead))]
        var images: [CGImage] = []
        for (name, pose) in list {
            var p = Player(side: 1); p.position = float3(0, 0, 8)
            for _ in 0..<120 {
                switch pose {
                case .idle: p.anim.update(dt: 1 / 60, localVelocity: .zero, maxSpeed: 7, swing: nil)
                case .run: p.anim.update(dt: 1 / 60, localVelocity: float2(0, 5.5), maxSpeed: 7, swing: nil)
                case .swing(let u, let k): p.anim.update(dt: 1 / 60, localVelocity: .zero, maxSpeed: 7, swing: (u, k))
                }
            }
            if case .swing(let u, let k) = pose {
                p.swingLift = k == .overhead ? 1.6 : 0.4; p.backhand = k == .backhand; p.swingTime = u * Player.swingDuration
                let rig = CharacterRig.evaluate(world: p.worldMatrix, pose: p.anim.pose)
                let d = simd_distance(rig.racketHead, p.racketPoint)
                print(String(format: "%@: animated racket head (%.2f, %.2f, %.2f) vs gameplay hit point (%.2f, %.2f, %.2f)  dist %.2f m",
                             name, rig.racketHead.x, rig.racketHead.y, rig.racketHead.z, p.racketPoint.x, p.racketPoint.y, p.racketPoint.z, d))
            }
            game.player = p
            r.camera.eye = float3(2.6, 1.7, 4.6); r.camera.target = float3(0, 1.0, 8); r.camera.fov = 0.6
            if let img = r.snapshotImage(width: w, height: h) { images.append(img) }
        }
        let sheet = CGContext(data: nil, width: w * 4, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, img) in images.enumerated() { sheet.draw(img, in: CGRect(x: (i % 4) * w, y: (1 - i / 4) * h, width: w, height: h)) }
        return Renderer.writePNG(sheet.makeImage()!, to: path) ? 0 : 1
    }

    /// `--crowd out.png`: close-up of the far stand, calm (left) vs right after a point is won (right), to check the audience animation.
    static func crowd(path: String) -> Int32 {
        var imgs: [CGImage] = []
        for cheer in [false, true] {
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let game = GameState()
            guard let r = Renderer(view: view, game: game, input: InputManager()) else { return 1 }
            game.phase = .rally; game.lastHitter = 1
            game.ball.position = float3(-3, 1.2, 2); game.opponent.position = float3(0, 0, -30)
            if cheer { game.phase = .serveReady; game.award(1, reason: "t") }
            r.camera.eye = float3(1.5, 2.2, -8); r.camera.target = float3(-2, 5.5, -26); r.camera.fov = 0.55
            guard let img = r.snapshotImage(width: 960, height: 540) else { return 1 }
            imgs.append(img)
        }
        let sheet = CGContext(data: nil, width: 1920, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, img) in imgs.enumerated() { sheet.draw(img, in: CGRect(x: i * 960, y: 0, width: 960, height: 540)) }
        return Renderer.writePNG(sheet.makeImage()!, to: path) ? 0 : 1
    }

    /// `--motion out.png`: plays an AI-vs-AI rally for 6 s, rendering every frame (so MetalFX history is live), and saves
    /// the last frame with the follow camera — used to check for ghosting/smearing on fast-moving objects.
    static func motion(path: String) -> Int32 {
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let game = GameState(); game.botControlsPlayer = true
        guard let r = Renderer(view: view, game: game, input: InputManager()) else { return 1 }
        let t = r.makeTargets(width: 1280, height: 720)
        r.cameraMode = .follow
        var i = 0
        // Run until a fast ball is in flight mid-rally (or 40 s), rendering every frame so temporal history is live.
        while i < 60 * 40 {
            game.update(frameDt: 1 / 60, input: InputState())
            r.camera.update(mode: .follow, player: game.player, ball: game.ball, dt: 1 / 60)
            r.renderOffscreen(t)
            i += 1
            if i > 240, game.phase == .rally, game.shotCount >= 3, simd_length(game.ball.velocity) > 20,
               abs(game.ball.position.z) < 9 { break }
        }
        print("captured at frame \(i)")
        print("phase \(game.phase) hits \(game.totalHits) ball \(game.ball.position) speed \(simd_length(game.ball.velocity))")
        guard let img = r.image(from: t) else { return 1 }
        return Renderer.writePNG(img, to: path) ? 0 : 1
    }

    /// `--face out.png`: head-and-shoulders close-ups of both athletes (skin, eyes, hair, expression), neutral and mid-effort.
    static func face(path: String) -> Int32 {
        var imgs: [CGImage] = []
        for (side, effort) in [(1.0 as Float, false), (-1.0 as Float, true)] {
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let game = GameState()
            guard let r = Renderer(view: view, game: game, input: InputManager()) else { return 1 }
            game.phase = .rally; game.lastHitter = 1
            game.ball.position = float3(side > 0 ? 3 : -2, 1.6, side * 3)
            game.player.position = float3(0, 0, 8); game.opponent.position = float3(0, 0, -8)
            for _ in 0..<30 { game.player.update(worldDir: .zero, maxSpeed: 7, dt: 1 / 60, lookAt: game.ball.position); game.opponent.update(worldDir: .zero, maxSpeed: 7, dt: 1 / 60, lookAt: game.ball.position) }
            if effort { game.opponent.expression.effort = 1; game.opponent.smileTarget = 0 }
            let z: Float = side > 0 ? 7.25 : -7.25, tz: Float = side > 0 ? 8 : -8
            r.camera.eye = float3(0.16, 1.75, z); r.camera.target = float3(0, 1.74, tz); r.camera.fov = 0.36
            guard let img = r.snapshotImage(width: 900, height: 900) else { return 1 }
            imgs.append(img)
        }
        let sheet = CGContext(data: nil, width: 1800, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, img) in imgs.enumerated() { sheet.draw(img, in: CGRect(x: i * 900, y: 0, width: 900, height: 900)) }
        return Renderer.writePNG(sheet.makeImage()!, to: path) ? 0 : 1
    }
}
