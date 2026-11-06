import Foundation
import simd
import Metal

/// Headless physics/gameplay checks: `TennisSim --selftest`. Returns process exit code.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)"); if !ok { failures += 1 }
        }
        let dt = GameState.fixedDt

        // 1. Free fall from 2 m: lands ~ sqrt(2h/g) with drag only slightly slower; first bounce apex < drop height.
        var b = Ball(); b.position = float3(0, 2, 5)
        var t: Float = 0, apex: Float = 0, bounced = false
        while t < 3 {
            let e = BallPhysics.step(&b, dt: dt); t += dt
            if case .bounce = e { bounced = true }
            if bounced { apex = max(apex, b.position.y) }
        }
        check("drop bounces, rebound < drop height", bounced && apex < 2 && apex > 0.8, String(format: "apex=%.2f", apex))

        // 2. Ball never goes below ground.
        check("never below ground", b.position.y >= Ball.radius - 1e-4)

        // 3. Topspin dips faster than backspin over same launch.
        func flight(spinSign: Float) -> Float {
            var q = Ball(); q.position = float3(0, 1, 11); q.velocity = float3(0, 3, -22)
            q.spin = float3(-1, 0, 0) * 200 * spinSign
            var tt: Float = 0
            while q.position.y > Ball.radius && tt < 3 { _ = BallPhysics.step(&q, dt: dt); tt += dt }
            return q.position.z
        }
        let top = flight(spinSign: 1), back = flight(spinSign: -1)
        check("topspin lands shorter than backspin", top > back, String(format: "top z=%.1f back z=%.1f", top, back))

        // 4. Net: low ball is stopped, high ball passes.
        var low = Ball(); low.position = float3(0, 0.5, 3); low.velocity = float3(0, 0, -20)
        var high = Ball(); high.position = float3(0, 1.8, 3); high.velocity = float3(0, 0, -20)
        for _ in 0..<240 { _ = BallPhysics.step(&low, dt: dt); _ = BallPhysics.step(&high, dt: dt) }
        check("net blocks low ball", low.position.z > 0, String(format: "z=%.2f", low.position.z))
        check("high ball clears net", high.position.z < -1, String(format: "z=%.2f", high.position.z))

        // 4b. Net cord. Sweep the start height of a ball flying at the net: low heights must be a net, a narrow band must be a
        // cord (trickles over), and higher heights must clear with no net event at all (monotone: net → cord → clear).
        func netOutcome(x: Float, y0: Float, speed: Float) -> (kind: Int, endZ: Float) {   // 0 net, 1 cord, 2 clear
            var q = Ball(); q.position = float3(x, y0, 2); q.velocity = float3(0, 0, -speed)
            var kind = 2
            for _ in 0..<480 { switch BallPhysics.step(&q, dt: dt) { case .netHit: if kind == 2 { kind = 0 }; case .netCord: if kind == 2 { kind = 1 }; default: break } }
            return (kind, q.position.z)
        }
        var sweep: [Int] = [], cordStart: Float? = nil, cordEnd: Float = 0
        var y0: Float = 0.9
        while y0 < 1.6 {
            let o = netOutcome(x: 1, y0: y0, speed: 12)
            sweep.append(o.kind)
            if o.kind == 1 && cordStart == nil { cordStart = y0; cordEnd = o.endZ }
            y0 += 0.001
        }
        let monotone = zip(sweep, sweep.dropFirst()).allSatisfy { $0 <= $1 }
        let cordWidth = Float(sweep.filter { $0 == 1 }.count) * 0.001
        check("net → cord → clear is monotone with start height", monotone && sweep.first == 0 && sweep.last == 2)
        check("cord band exists, is narrow (<5 cm) and the ball ends over the net", cordStart != nil && cordWidth > 0 && cordWidth < 0.05 && cordEnd < 0,
              String(format: "band %.1f cm, end z=%.2f", cordWidth * 100, cordEnd))

        // 4c. Let: a serve that clips the cord and still lands in the box is replayed without using up a serve.
        var letStart: Float? = nil
        var yy: Float = 0.9
        while yy < 1.6, letStart == nil { if netOutcome(x: -0.6, y0: yy, speed: 14).kind == 1 { letStart = yy }; yy += 0.001 }
        let lg = GameState()
        lg.phase = .rally; lg.lastHitter = 1; lg.shotCount = 1; lg.ball = Ball()
        lg.ball.position = float3(-0.6, (letStart ?? 1.2) + 0.002, 2); lg.ball.velocity = float3(0, 0, -14)
        var letSeen = false, last = ""
        for _ in 0..<(60 * 4) { lg.update(frameDt: 1.0 / 60, input: InputState()); if lg.lastEvent != last { last = lg.lastEvent; print("   [let test] \(last)") }; if lg.lastEvent.contains("Let") { letSeen = true; break } }
        check("serve net-cord + in the box → let, serve replayed", letSeen && lg.serveNumber == 1 && lg.phase == .serveReady, "event=\(lg.lastEvent) serve#\(lg.serveNumber)")

        // 5. Gameplay: serve (toss, swing) produces a ball that crosses the net and bounces in the opposite half.
        let g = GameState()
        var inp = InputState()
        inp.swingPressed = true; g.update(frameDt: 1.0 / 60, input: inp)          // toss
        inp.swingPressed = false
        var swung = false, landedZ: Float? = nil, crossed = false
        for _ in 0..<(60 * 4) {
            if !swung && g.ball.velocity.y < 0 && g.ball.position.y < 3.0 { inp.swingPressed = true; swung = true } else { inp.swingPressed = false }
            g.update(frameDt: 1.0 / 60, input: inp)
            if ProcessInfo.processInfo.environment["TS_TRACE"] != nil { print(String(format: "p=%@ y=%.2f z=%.2f vz=%.1f %@", "\(g.phase)", g.ball.position.y, g.ball.position.z, g.ball.velocity.z, g.lastEvent)) }
            if g.ball.position.z < 0 { crossed = true }
            if landedZ == nil, g.ball.bounces > 0, g.phase == .rally { landedZ = g.ball.position.z }
        }
        check("serve hit registered", g.phase == .rally || landedZ != nil, "phase=\(g.phase) last=\(g.lastEvent)")
        check("serve crosses net", crossed)
        check("serve lands in opposite half", (landedZ ?? 1) < 0 && abs(landedZ ?? 99) < Court.halfLength + 1, "landedZ=\(landedZ.map { String(format: "%.1f", $0) } ?? "nil")")

        // 6. Player movement bounded.
        var p = Player(side: 1)
        for _ in 0..<600 { p.update(worldDir: float3(1, 0, -1), maxSpeed: 7, dt: 1.0 / 60) }
        check("player stays in bounds", p.position.x <= 7.5 && p.position.z >= 0.8)

        // 7. Scoring: game at 4 points, deuce needs a 2-point lead, server alternates, set at 6 games.
        let sg = GameState()
        for _ in 0..<4 { sg.award(1, reason: "t"); sg.phase = .serveReady }
        check("game won at 4 points", sg.games == [1, 0] && sg.points == [0, 0] && sg.server == -1, "games=\(sg.games) server=\(sg.server)")
        for _ in 0..<3 { sg.award(1, reason: "t"); sg.phase = .serveReady; sg.award(-1, reason: "t"); sg.phase = .serveReady }
        check("deuce: 3-3 no game", sg.games == [1, 0] && sg.points == [3, 3], "pts=\(sg.points)")
        sg.award(1, reason: "t"); sg.phase = .serveReady
        check("advantage: 4-3 no game", sg.games == [1, 0] && sg.scoreText.contains("Ad"), sg.scoreText)
        sg.award(1, reason: "t"); sg.phase = .serveReady
        check("win by two from deuce", sg.games == [2, 0], "games=\(sg.games)")
        let sw = GameState()
        for _ in 0..<(6 * 4) { sw.award(1, reason: "t"); sw.phase = .serveReady }
        check("set won at 6 games", sw.matchWinner == 0 && sw.games == [6, 0], "winner=\(String(describing: sw.matchWinner))")

        // 7b. Tiebreak: reached at 6-6, first to 7 (win by 2), server rotation 1-2-2-2…
        let tb = GameState()
        for g in 0..<12 { for _ in 0..<4 { tb.award(g % 2 == 0 ? 1 : -1, reason: "t"); tb.phase = .serveReady } }
        check("tiebreak starts at 6-6", tb.inTiebreak && tb.games == [6, 6] && tb.points == [0, 0], "games=\(tb.games) tb=\(tb.inTiebreak)")
        let firstServer = tb.server
        tb.award(-1, reason: "t"); tb.phase = .serveReady
        let s1 = tb.server
        tb.award(-1, reason: "t"); tb.phase = .serveReady
        let s2 = tb.server
        tb.award(-1, reason: "t"); tb.phase = .serveReady
        let s3 = tb.server
        check("tiebreak server rotation", s1 == -firstServer && s2 == -firstServer && s3 == firstServer, "\(firstServer) \(s1) \(s2) \(s3)")
        for _ in 0..<6 { tb.award(1, reason: "t"); tb.phase = .serveReady }       // 6-3 -> not yet over
        check("tiebreak needs 7", tb.matchWinner == nil && tb.points == [6, 3], "pts=\(tb.points)")
        tb.award(1, reason: "t")
        check("tiebreak won 7-3 -> set 7-6", tb.matchWinner == 0 && tb.games == [7, 6], "games=\(tb.games) winner=\(String(describing: tb.matchWinner))")

        // 7c. Animation smoke test: no discontinuities (a real pop is ~1 rad in one frame; natural motion peaks lower) and the lowest foot must stay planted on the ground.
        var an = Animator(), maxLoco: Float = 0, maxEdge: Float = 0, maxClip: Float = 0, worstFoot: Float = 0
        an.update(dt: 1.0 / 60, localVelocity: .zero, maxSpeed: 7, swing: nil)      // warm-up: zero pose -> idle isn't a pop
        var prev = an.pose
        func stepAnim(_ n: Int, vel: float2, swing: ((Float, SwingKind))?, uStart: Float = 0, uEnd: Float = 0) {
            for i in 0..<n {
                let sw = swing.map { sk in (uStart + (uEnd - uStart) * Float(i) / Float(max(n - 1, 1)), sk.1) }
                an.update(dt: 1.0 / 60, localVelocity: vel, maxSpeed: 7, swing: sw)
                var step: Float = 0
                for j in 0..<an.pose.angles.count { step = max(step, simd_length(an.pose.angles[j] - prev.angles[j])) }
                if swing == nil { maxLoco = max(maxLoco, step) }
                else if i < 2 || i >= n - 3 { maxEdge = max(maxEdge, step) }       // blend-in / blend-out of the swing layer
                else { maxClip = max(maxClip, step) }                              // the clip's own (intentionally fast) motion
                prev = an.pose
                let rig = CharacterRig.evaluate(world: matrix_identity_float4x4, pose: an.pose)
                let ankles = rig.parts.filter { $0.0 == .shoe }.map { $0.1.columns.3.y }
                worstFoot = max(worstFoot, abs((ankles.min() ?? 0) - CharacterRig.soleOffset * CharacterRig.scale))
            }
        }
        stepAnim(60, vel: .zero, swing: nil)                                            // idle
        stepAnim(120, vel: float2(0, 6), swing: nil)                                    // accelerate into a run
        stepAnim(21, vel: float2(0, 6), swing: (0, .forehand), uStart: 0, uEnd: 1)      // forehand while running (0.35 s)
        stepAnim(60, vel: .zero, swing: nil)                                            // stop
        stepAnim(21, vel: .zero, swing: (0, .overhead), uStart: 0, uEnd: 1)       // serve
        check("locomotion blending continuous", maxLoco < 0.2, String(format: "max=%.3f rad/frame", maxLoco))
        check("swing blend-in/out continuous", maxEdge < 0.45, String(format: "max=%.3f rad/frame (clip interior peaks at %.2f)", maxEdge, maxClip))
        check("feet stay planted", worstFoot < 0.01, String(format: "worst ankle error=%.4f m", worstFoot))
        // Animated racket head must reach the gameplay hit point at contact.
        var cp = Player(side: 1); cp.position = float3(0, 0, 8)
        for _ in 0..<60 { cp.anim.update(dt: 1.0 / 60, localVelocity: .zero, maxSpeed: 7, swing: nil) }
        for (u, kind, lift, bh, name): (Float, SwingKind, Float, Bool, String) in
            [(0.45, .forehand, 0.4, false, "forehand"), (0.45, .backhand, 0.4, true, "backhand"), (0.5, .overhead, 1.6, false, "serve/smash")] {
            var q = cp; q.swingLift = lift; q.backhand = bh; q.swingTime = u * Player.swingDuration
            for _ in 0..<30 { q.anim.update(dt: 1.0 / 60, localVelocity: .zero, maxSpeed: 7, swing: (u, kind)) }
            let d = simd_distance(CharacterRig.evaluate(world: q.worldMatrix, pose: q.anim.pose).racketHead, q.racketPoint)
            check("racket head near hit point at contact (\(name))", d < Player.reach * 0.5, String(format: "dist=%.2f m", d))
        }

        // 7d. Skinned athlete: asset loads, weights are normalised, and the zero-pose palette straightens the A-pose arms
        // (rest-pose width ≈ 0.95 m → hanging arms < 0.7 m) while keeping the character ~1.9 m tall and finite.
        if let dev = MTLCreateSystemDefaultDevice(), let url = Bundle.main.url(forResource: "athlete", withExtension: "hum"),
           let model = AthleteModel(device: dev, url: url), let body = model.parts["body"] {
            check("athlete asset has 17 bones and 10 parts", model.boneCount == 17 && model.parts.count == 10, "bones=\(model.boneCount) parts=\(model.parts.count)")
            let rig = CharacterRig.evaluate(world: matrix_identity_float4x4, pose: Pose())
            let pal = CharacterRig.palette(frames: rig.frames, model: model, expression: Expression())
            let base = body.vertexBuffer.contents()
            var minX: Float = 9, maxX: Float = -9, minY: Float = 9, maxY: Float = -9, finite = true, wsumErr: Float = 0
            let n = body.vertexCount
            for i in stride(from: 0, to: n, by: 3) {
                let v = base + i * AthleteModel.vertexStride
                let pos = v.loadUnaligned(fromByteOffset: 0, as: SIMD3<Float>.self)
                let j = v.loadUnaligned(fromByteOffset: 36, as: SIMD4<UInt8>.self)
                let w = v.loadUnaligned(fromByteOffset: 48, as: SIMD4<Float>.self)
                var out = SIMD4<Float>(repeating: 0)
                for k in 0..<4 { out += pal[Int(j[k])] * SIMD4<Float>(pos, 1) * w[k] }
                finite = finite && out.x.isFinite && out.y.isFinite
                minX = min(minX, out.x); maxX = max(maxX, out.x); minY = min(minY, out.y); maxY = max(maxY, out.y)
                wsumErr = max(wsumErr, abs(w.x + w.y + w.z + w.w - 1))
            }
            check("skin weights normalised", wsumErr < 1e-3, String(format: "max err %.5f", wsumErr))
            check("zero-pose skinning straightens arms (|x| < 0.70) and stays ~1.9 m tall", finite && max(abs(minX), abs(maxX)) < 0.70 && maxY > 1.85 && maxY < 2.0 && minY > -0.05,
                  String(format: "x∈[%.2f, %.2f] y∈[%.2f, %.2f]", minX, maxX, minY, maxY))
        } else { check("athlete asset loads", false, "athlete.hum missing from the app bundle") }

        // 7e. Umpire calls (server's score first) and slow-motion after a point.
        let ug = GameState(); ug.slowMoEnabled = false
        ug.award(1, reason: "t"); ug.phase = .serveReady
        check("call: 15–love when the server leads", ug.announcement == "fifteen, love", ug.announcement ?? "nil")
        ug.award(-1, reason: "t"); ug.phase = .serveReady
        check("call: 15 all", ug.announcement == "fifteen all", ug.announcement ?? "nil")
        ug.award(1, reason: "t"); ug.phase = .serveReady; ug.award(1, reason: "t"); ug.phase = .serveReady
        check("call: 40–15", ug.announcement == "forty, fifteen", ug.announcement ?? "nil")
        ug.award(-1, reason: "t"); ug.phase = .serveReady; ug.award(-1, reason: "t"); ug.phase = .serveReady
        check("call: deuce", ug.announcement == "Deuce", ug.announcement ?? "nil")
        ug.award(1, reason: "t"); ug.phase = .serveReady
        check("call: advantage", ug.announcement == "Advantage you", ug.announcement ?? "nil")
        ug.award(1, reason: "t")
        check("call: game", (ug.announcement ?? "").hasPrefix("Game, you."), ug.announcement ?? "nil")
        let sm = GameState(); sm.award(1, reason: "t")
        var minScale: Float = 1
        for _ in 0..<240 { sm.update(frameDt: 1.0 / 60, input: InputState()); minScale = min(minScale, sm.timeScale) }
        check("slow motion after a point eases back to real time", minScale < 0.5 && sm.timeScale > 0.99, String(format: "min %.2f end %.2f", minScale, sm.timeScale))

        // 7f. Shot calibration: simulate many shots of each type (bot parameters) and measure where they land.
        //     Each type must go in a healthy share of the time, or skill would stop mattering (luck would decide points).
        let sg2 = GameState(); sg2.slowMoEnabled = false
        var report: [String] = []
        for st in ShotType.allCases {
            var inC = 0, outC = 0, netC = 0, longC = 0, wideC = 0, sumZ: Float = 0, nZ: Float = 0
            for i in 0..<400 {
                let start = float3(Float(i % 9) * 0.7 - 2.8, 1.0, 10.8 + Float(i % 5) * 0.2)
                let plan = sg2.planShot(side: 1, from: start, shot: st, serving: false, isHuman: false, playerX: start.x, quality: 1)
                var bb = Ball(); bb.position = start; bb.velocity = plan.velocity; bb.spin = plan.spin
                var result = 0   // 0 in, 1 out, 2 net
                var done = false
                for _ in 0..<(240 * 4) where !done {
                    switch BallPhysics.step(&bb, dt: 1.0 / 240) {
                    case .netHit: result = 2; done = true
                    case .bounce(let q):
                        result = (q.z < 0 && abs(q.x) <= Court.halfWidthSingles && q.z > -Court.halfLength) ? 0 : 1; done = true
                        if q.z <= -Court.halfLength { longC += 1 }; if abs(q.x) > Court.halfWidthSingles { wideC += 1 }
                        sumZ += q.z; nZ += 1
                    default: break
                    }
                }
                if !done { result = 1 }
                switch result { case 0: inC += 1; case 1: outC += 1; default: netC += 1 }
            }
            report.append("\(st.name) in \(inC * 100 / 400)% out \(outC * 100 / 400)% (long \(longC * 100 / 400)%, wide \(wideC * 100 / 400)%) net \(netC * 100 / 400)%, mean landing z \(String(format: "%.1f", sumZ / max(nZ, 1)))")
            check("shot type \(st.name) is in at least 70% of the time", inC * 100 / 400 >= 70, report.last!)
        }

        // 7g. Audio synthesis (no audio device needed): every effect is audible, finite and within range.
        func level(_ x: [Float]) -> (rms: Float, peak: Float, finite: Bool) {
            let rms = sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
            return (rms, x.map { abs($0) }.max() ?? 0, x.allSatisfy { $0.isFinite })
        }
        for (name, samples) in [("hit (soft)", GameAudio.hitSamples(hardness: 0.1, seed: 1)), ("hit (hard)", GameAudio.hitSamples(hardness: 1, seed: 2)),
                                ("bounce", GameAudio.bounceSamples()), ("net", GameAudio.netSamples()), ("cheer", GameAudio.cheerSamples()), ("crowd loop", GameAudio.crowdLoopSamples())] {
            let l = level(samples)
            check("audio: \(name) is audible, finite and not clipping", l.finite && l.rms > 0.005 && l.peak <= 1.0 + 1e-3, String(format: "rms %.3f peak %.2f, %.2f s", l.rms, l.peak, Double(samples.count) / GameAudio.sampleRate))
        }
        let loop = GameAudio.crowdLoopSamples()
        check("audio: crowd loop joins without a click", abs(loop.first! - loop.last!) < 0.25, String(format: "ends %.3f → %.3f", loop.last!, loop.first!))
        let hardRMS = level(GameAudio.hitSamples(hardness: 1, seed: 2)).rms, softRMS = level(GameAudio.hitSamples(hardness: 0.1, seed: 1)).rms
        check("audio: hard hits are louder than soft hits", hardRMS > softRMS, String(format: "%.3f vs %.3f", hardRMS, softRMS))

        // 8. Autoplay: AI vs AI for 3 simulated minutes. Rallies must develop and points must be decided; nothing may get stuck.
        let ap = GameState(); ap.botControlsPlayer = true; ap.slowMoEnabled = false
        let idle = InputState()
        var apLast = ""
        var maxPointGap: Float = 0, sinceLast: Float = 0, lastPts = 0
        for _ in 0..<(60 * 180) {
            ap.update(frameDt: 1.0 / 60, input: idle)
            if ProcessInfo.processInfo.environment["TS_AP"] != nil, ap.lastEvent != apLast { apLast = ap.lastEvent; print(String(format: "[%@] hits=%d %@ ball z=%.1f", "\(ap.phase)", ap.totalHits, ap.lastEvent, ap.ball.position.z)) }
            sinceLast += 1.0 / 60
            if ap.pointsPlayed != lastPts { lastPts = ap.pointsPlayed; sinceLast = 0 }
            maxPointGap = max(maxPointGap, sinceLast)
            if ProcessInfo.processInfo.environment["TS_AP"] != nil, sinceLast > 20, Int(sinceLast * 60) % 120 == 0 {
                print(String(format: "[stall %.0fs] phase=%@ last=%@ ball=(%.1f,%.1f,%.1f) v=(%.1f,%.1f,%.1f) bounces=%d/%d lastHitter=%.0f shot=%d P=(%.1f,%.1f) O=(%.1f,%.1f)", sinceLast, "\(ap.phase)", ap.lastEvent, ap.ball.position.x, ap.ball.position.y, ap.ball.position.z, ap.ball.velocity.x, ap.ball.velocity.y, ap.ball.velocity.z, ap.ball.bounces, ap.ball.bouncesSinceHit, ap.lastHitter, ap.shotCount, ap.player.position.x, ap.player.position.z, ap.opponent.position.x, ap.opponent.position.z))
            }
            if ap.matchWinner != nil { break }
        }
        print("autoplay stats: points=\(ap.pointsPlayed) hits=\(ap.totalHits) longestRally=\(ap.longestRally) doubleFaults=\(ap.doubleFaults) games=\(ap.games) maxGap=\(String(format: "%.1f", maxPointGap))s")
        check("autoplay decides many points", ap.pointsPlayed >= 15, "points=\(ap.pointsPlayed)")
        check("autoplay produces rallies (>=3 shots)", ap.longestRally >= 3, "longest=\(ap.longestRally)")
        print("   shot error rates (out/net) by type:", ShotType.allCases.map { "\($0.name) \(ap.shotTypeErrors[$0.rawValue])/\(ap.shotTypeCounts[$0.rawValue])" }.joined(separator: ", "))
        check("all four shot types are played (topspin/slice/lob/drop)", ap.shotTypeCounts.allSatisfy { $0 > 0 }, "counts=\(ap.shotTypeCounts)")
        check("autoplay never stuck", maxPointGap < 32, String(format: "maxGap=%.1fs", maxPointGap))

        // 9. Difficulty matters: a hard-skill bot should beat an easy AI over a long simulated match (several 6-game sets).
        var hardPoints = 0, easyPoints = 0
        for _ in 0..<12 {
            let m = GameState(); m.botControlsPlayer = true; m.slowMoEnabled = false
            m.playerBot.maxSpeed = Difficulty.hard.speed; m.playerBot.errorMagnitude = Difficulty.hard.error
            m.difficulty = .easy
            for _ in 0..<(60 * 240) { m.update(frameDt: 1.0 / 60, input: idle); if m.matchWinner != nil { break } }
            hardPoints += m.pointsWon[0]; easyPoints += m.pointsWon[1]
        }
        check("hard bot out-scores easy AI", hardPoints > easyPoints, "hard=\(hardPoints) easy=\(easyPoints)")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
