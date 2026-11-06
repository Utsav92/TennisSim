import simd

/// Game simulation: players, ball, serve/rally/scoring rules. Pure Swift, no rendering dependencies (testable headless).
/// Rules implemented: points 0/15/30/40/deuce/advantage, games, one set (first to 6 games, win by 2, no tiebreak),
/// two serves with fault/double-fault, in/out via singles lines, second-bounce and net errors.
/// Not implemented: diagonal service box, lets, side changes, tiebreaks.
enum ShotType: Int, CaseIterable {
    case topspin, slice, lob, drop
    var name: String { ["topspin", "slice", "lob", "drop shot"][rawValue] }
}

/// Things that happened this frame, consumed by audio, haptics and effects (drained by the Renderer).
enum GameEvent {
    case hit(side: Float, speed: Float, quality: Float, shot: ShotType, position: float3)
    case bounce(position: float3, speed: Float)
    case net, netCord, point(side: Float), fault, letCall
}

enum Difficulty: Int, CaseIterable {
    case easy, medium, hard
    var name: String { ["Easy", "Medium", "Hard"][rawValue] }
    var speed: Float { [4.2, 5.0, 6.2][rawValue] }
    var error: Float { [1.6, 1.1, 0.5][rawValue] }
}

final class GameState {
    var paused = false
    var events: [GameEvent] = []
    /// Visual-only state: recent ball positions (motion trail) and bounce marks left on clay / grass (fade with age).
    var ballTrail: [float3] = []
    var ballMarks: [(pos: float3, age: Float)] = []
    var announcement: String? = nil          // umpire call to speak, set when something is called
    private(set) var shake: Float = 0       // camera shake amount 0…1 (hard hits), decays
    var slowMoEnabled = true                 // brief slow motion after a point
    private(set) var timeScale: Float = 1
    private var pointOverReal: Float = 0
    var difficulty: Difficulty = .medium { didSet { ai.maxSpeed = difficulty.speed; ai.errorMagnitude = difficulty.error } }
    var player = Player(side: 1)
    var opponent = Player(side: -1)
    var ball = Ball()
    enum Phase { case serveReady, tossed, rally, pointOver }
    var phase: Phase = .serveReady
    var server: Float = 1               // side of the server
    var serveNumber = 1
    var lastHitter: Float = 0           // side of last player to hit (0 = nobody yet)
    var shotCount = 0                   // shots in the current point (1 = the serve)
    var points = [0, 0]                 // [human, opponent]
    var games = [0, 0]
    var matchWinner: Int? = nil
    var inTiebreak = false
    private var tiebreakFirstServer: Float = 1
    var timer: Float = 0                // seconds since phase began
    var rallyTime: Float = 0
    var lastEvent = ""
    /// Crowd excitement 0…1: spikes when a point is won, rises with long rallies, decays smoothly. Drives the audience animation.
    private(set) var crowdExcitement: Float = 0.08
    var scoreText = ""
    /// Scoreboard content: [human, opponent] game counts and point strings ("15", "Ad", tiebreak numbers…).
    private(set) var displayPoints = ["0", "0"]
    var botControlsPlayer = false       // autoplay for tests
    var ai = AIController()
    var playerBot = AIController()
    // Stats (for tests / HUD)
    var pointsWon = [0, 0]              // cumulative [human, opponent] across games
    var shotTypeCounts = [Int](repeating: 0, count: ShotType.allCases.count)   // shots hit per type (stats / tests)
    var shotTypeErrors = [Int](repeating: 0, count: ShotType.allCases.count)   // of those, how many ended as out/net errors
    private var lastShotType = ShotType.topspin
    var pointsPlayed = 0, totalHits = 0, longestRally = 0, doubleFaults = 0

    /// Sign of the x-side the server stands on (+1 = +x half). The serve must land in the diagonally opposite box.
    private(set) var serveSideSign: Float = 1
    private var serveLet = false           // the serve clipped the net cord (a let if it still lands in the box)
    private var accumulator: Float = 0
    private var humanAimX: Float = 0
    private var rngState: UInt64 = 0x9E3779B97F4A7C15
    static let fixedDt: Float = 1.0 / 240.0

    init() { startPoint() }

    private func rand() -> Float {
        rngState ^= rngState << 13; rngState ^= rngState >> 7; rngState ^= rngState << 17
        return Float(rngState % 10_000) / 10_000
    }
    private func idx(_ side: Float) -> Int { side > 0 ? 0 : 1 }

    // MARK: Point / match flow

    func newMatch() {
        ballMarks.removeAll(); ballTrail.removeAll()
        points = [0, 0]; games = [0, 0]; matchWinner = nil; server = 1; inTiebreak = false
        startPoint()
    }

    func startPoint() {
        phase = .serveReady; timer = 0; rallyTime = 0
        serveNumber = 1; lastHitter = 0; shotCount = 0; serveLet = false
        positionForServe()
        lastEvent = server > 0 ? "Your serve — swing to toss, swing again to hit" : "Opponent serving"
        refreshScore()
    }

    private func positionForServe() {
        let even = (points[0] + points[1]) % 2 == 0
        let sx: Float = (even ? 2.0 : -2.0) * server        // server: right-hand side of centre mark
        serveSideSign = sx > 0 ? 1 : -1
        var s = server > 0 ? player : opponent
        var r = server > 0 ? opponent : player
        s.position = float3(sx, 0, server * 12.0); s.velocity = .zero
        r.position = float3(-sx * 0.5, 0, -server * 11.5); r.velocity = .zero
        s.swingTime = 10; r.swingTime = 10
        if server > 0 { player = s; opponent = r } else { opponent = s; player = r }
        placeBallInHand()
    }

    private func serverPlayer() -> Player { server > 0 ? player : opponent }

    private func placeBallInHand() {
        let s = serverPlayer()
        ball = Ball()
        ball.position = s.position + s.right * 0.6 + s.forward * 0.4 + float3(0, 1.1, 0)
    }

    func award(_ side: Float, reason: String) {
        guard phase != .pointOver else { return }
        let w = idx(side), l = 1 - w
        points[w] += 1; pointsPlayed += 1; pointsWon[w] += 1
        longestRally = max(longestRally, totalHitsThisPoint)
        if reason == "Out" || reason == "Net" { shotTypeErrors[lastShotType.rawValue] += 1 }
        let name = side > 0 ? "You" : "Opponent"
        lastEvent = "\(reason) — point \(name)"
        // Bigger reaction for long rallies and for the home player's points.
        let spike: Float = 0.55 + min(0.3, Float(shotCount) * 0.03) + (side > 0 ? 0.15 : 0)
        crowdExcitement = max(crowdExcitement, min(1, spike))
        if side > 0 { player.smileTarget = 1 } else { opponent.smileTarget = 1 }
        var gameWon = false
        if inTiebreak {
            // Tiebreak: first to 7 points, win by 2; server changes after the first point and then every two points.
            if points[w] >= 7 && points[w] - points[l] >= 2 {
                games[w] += 1; matchWinner = w; gameWon = true
                lastEvent = "\(name) win the tiebreak and the set \(games[0])–\(games[1])! Press R for a new match"
            } else {
                let total = points[0] + points[1]
                server = ((total + 1) / 2) % 2 == 0 ? tiebreakFirstServer : -tiebreakFirstServer
            }
        } else if points[w] >= 4 && points[w] - points[l] >= 2 {
            games[w] += 1; points = [0, 0]; server = -server; gameWon = true
            lastEvent += " · game \(name)"
            if games[w] >= 6 && games[w] - games[l] >= 2 {
                matchWinner = w
                lastEvent = "\(name) win the set \(games[0])–\(games[1])! Press R for a new match"
            } else if games == [6, 6] {
                inTiebreak = true; tiebreakFirstServer = server
                lastEvent += " · tiebreak!"
            }
        }
        phase = .pointOver; timer = 0
        refreshScore()
        events.append(.point(side: side))
        announcement = umpireCall(winner: w, gameWon: gameWon, over: matchWinner != nil, tiebreakStart: inTiebreak && gameWon && matchWinner == nil)
    }
    /// Spoken umpire call: score (server first), "Deuce", "Advantage …", or the game / match result.
    private func umpireCall(winner w: Int, gameWon: Bool, over: Bool, tiebreakStart: Bool) -> String {
        let who = w == 0 ? "you" : "your opponent"
        if over { return "Game, set and match. \(w == 0 ? "You win" : "Your opponent wins"), \(games[0]) games to \(games[1])." }
        if gameWon {
            let g = games[0] == games[1] ? "\(games[0]) all" : (games[0] > games[1] ? "\(games[0]) games to \(games[1]), you lead" : "\(games[1]) games to \(games[0]), your opponent leads")
            return "Game, \(who). \(g)\(tiebreakStart ? ". Tiebreak." : "")"
        }
        let names = ["love", "fifteen", "thirty", "forty"]
        let sIdx = idx(server), rIdx = 1 - sIdx
        let sp = points[sIdx], rp = points[rIdx]
        if inTiebreak { return sp == rp ? "\(sp) all" : "\(sp), \(rp)" }
        if sp >= 3 && rp >= 3 {
            if sp == rp { return "Deuce" }
            return "Advantage \(sp > rp ? (server > 0 ? "you" : "your opponent") : (server > 0 ? "your opponent" : "you"))"
        }
        if sp == rp { return "\(names[min(sp, 3)]) all" }
        return "\(names[min(sp, 3)]), \(names[min(rp, 3)])"
    }
    private var totalHitsThisPoint: Int { shotCount }

    private func serveFault(_ reason: String) {
        if serveNumber == 1 {
            serveNumber = 2; phase = .serveReady; timer = 0; lastHitter = 0; shotCount = 0; serveLet = false
            placeBallInHand(); lastEvent = "Fault (\(reason)) — second serve"
            events.append(.fault); announcement = "Fault"
        } else {
            doubleFaults += 1
            award(-server, reason: "Double fault")
        }
        refreshScore()
    }

    private func refreshScore() {
        func pts(_ a: Int, _ b: Int) -> String {
            if inTiebreak { return "\(a)" }
            if a >= 3 && b >= 3 { return a == b ? "40" : (a > b ? "Ad" : "40") }
            return ["0", "15", "30", "40"][min(a, 3)]
        }
        var left = pts(points[0], points[1]), right = pts(points[1], points[0])
        if !inTiebreak && points[0] >= 3 && points[0] == points[1] { left = "Deuce"; right = "" }
        displayPoints = [left == "Deuce" ? "40" : left, left == "Deuce" ? "40" : right]
        let srv = server > 0 ? "● You" : "  You"
        let srvO = server < 0 ? "● AI" : "  AI"
        scoreText = (inTiebreak ? "[TB] " : "") + "\(srv) \(games[0]) | \(left)      \(srvO) \(games[1]) | \(right)"
    }

    // MARK: Update

    func update(frameDt: Float, input: InputState) {
        let realDt = min(frameDt, 0.1)
        if paused { return }
        shake = max(0, shake - realDt * 2.8)
        for i in ballMarks.indices { ballMarks[i].age += realDt }
        ballMarks.removeAll { $0.age > 45 }
        if simd_length(ball.velocity) > 12 && ball.position.y > 0.05 { ballTrail.append(ball.position); if ballTrail.count > 7 { ballTrail.removeFirst() } }
        else if !ballTrail.isEmpty { ballTrail.removeFirst() }
        if phase == .pointOver && slowMoEnabled {
            pointOverReal += realDt
            let t = simd_clamp((pointOverReal - 0.7) / 0.8, 0, 1)
            timeScale = 0.35 + 0.65 * t * t * (3 - 2 * t)
        } else { pointOverReal = 0; timeScale = 1 }
        let dt = realDt * timeScale
        timer += dt
        // Baseline interest grows with the rally; spikes from points decay over a few seconds.
        let baseline: Float = phase == .rally ? min(0.3, 0.08 + Float(shotCount) * 0.03) : 0.08
        crowdExcitement = baseline + (crowdExcitement - baseline) * expf(-0.55 * dt)
        if input.resetPressed { newMatch() }
        if matchWinner != nil { return }

        var pDir = float3(input.move.x, 0, -input.move.y)
        var pSwing = input.swingPressed
        var pShot = input.shot
        if botControlsPlayer {
            let c = playerBot.control(me: player, game: self, dt: dt)
            pDir = c.dir; pSwing = c.swing; pShot = c.shot
        } else {
            humanAimX = input.move.x
        }
        let c2 = ai.control(me: opponent, game: self, dt: dt)
        player.update(worldDir: pDir, maxSpeed: botControlsPlayer ? playerBot.maxSpeed : 7.0, dt: dt, lookAt: ball.position)
        opponent.update(worldDir: c2.dir, maxSpeed: ai.maxSpeed, dt: dt, lookAt: ball.position)
        act(side: 1, swing: pSwing, shot: pShot)
        act(side: -1, swing: c2.swing, shot: c2.shot)

        if phase == .serveReady { placeBallInHand(); return }
        if phase == .pointOver {
            stepBall(dt: dt)
            if timer > 2.0 { startPoint() }
            return
        }
        rallyTime += dt
        stepBall(dt: dt)
        if rallyTime > 30 { startPoint() }   // safety net: never get stuck
    }

    private func act(side: Float, swing: Bool, shot: ShotType = .topspin) {
        guard swing else { return }
        switch phase {
        case .serveReady:
            if server == side {
                ball.velocity = float3(0, 6.2, 0); phase = .tossed; timer = 0
                lastEvent = side > 0 ? "Tossed — swing to hit" : "Opponent tosses"
            }
        case .tossed, .rally:
            // Swing kind from the ball's position at swing time: serve or high ball → overhead; ball on the left → backhand.
            let p = side > 0 ? player : opponent
            let serving = phase == .tossed && server == side
            let overhead = serving || ball.position.y > 2.3
            let backhand = !overhead && simd_dot(ball.position - p.position, p.right) < -0.15
            let lift: Float = overhead ? 1.6 : 0.4
            if side > 0 { player.startSwing(lift: lift, backhand: backhand, shot: shot) } else { opponent.startSwing(lift: lift, backhand: backhand, shot: shot) }
        case .pointOver: break
        }
    }

    private func stepBall(dt: Float) {
        accumulator += dt
        while accumulator >= Self.fixedDt {
            accumulator -= Self.fixedDt
            let ev = BallPhysics.step(&ball, dt: Self.fixedDt)
            if phase != .pointOver {
                switch ev {
                case .bounce(let p):
                    ballMarks.append((float3(p.x, 0, p.z), 0)); if ballMarks.count > 28 { ballMarks.removeFirst() }
                    events.append(.bounce(position: p, speed: simd_length(ball.velocity))); handleBounce(p)
                case .netHit: lastEvent = "Net!"; events.append(.net)
                case .netCord:
                    lastEvent = "Net cord!"; events.append(.netCord)
                    if shotCount == 1 { serveLet = true }
                case .none: break
                }
            }
            if phase == .tossed || phase == .rally {
                attemptHit(side: 1); attemptHit(side: -1)
            }
        }
    }

    private func handleBounce(_ p: float3) {
        if lastHitter == 0 {
            // Toss dropped without being hit: re-toss (no penalty).
            phase = .serveReady; timer = 0; placeBallInHand(); lastEvent = "Toss missed — try again"
            return
        }
        let h = lastHitter, opp = -h
        let S = Court.halfWidthSingles + Ball.radius, L = Court.halfLength + Ball.radius
        if ball.bouncesSinceHit == 1 {
            let onOppSide = p.z * opp > 0
            var inBounds = onOppSide && abs(p.x) <= S && abs(p.z) <= L
            if shotCount == 1 {   // service box: short of the service line and in the diagonally opposite half
                inBounds = inBounds && abs(p.z) <= Court.serviceLineZ + Ball.radius && p.x * serveSideSign <= Ball.radius
            }
            if !inBounds {
                if shotCount == 1 { serveFault(onOppSide ? "out" : "net") }
                else { award(opp, reason: onOppSide ? "Out" : "Net") }
            } else {
                if shotCount == 1 && serveLet {          // in the box after clipping the net: let, replay the same serve
                    serveLet = false
                    phase = .serveReady; timer = 0; lastHitter = 0; shotCount = 0
                    placeBallInHand(); lastEvent = "Let — replay the serve"
                    events.append(.letCall); announcement = "Let"
                    return
                }
                lastEvent = String(format: "In — x %.1f z %.1f", p.x, p.z)
            }
        } else if ball.bouncesSinceHit >= 2 {
            award(h, reason: "Winner")
        }
    }

    private func attemptHit(side: Float) {
        var p = side > 0 ? player : opponent
        defer { if side > 0 { player = p } else { opponent = p } }
        guard p.isSwinging, !p.swingHit, p.swingProgress > 0.1, p.swingProgress < 0.85 else { return }
        guard simd_distance(ball.position, p.racketPoint) < Player.reach * 0.9 + Ball.radius else { return }
        let serving = phase == .tossed
        if serving { guard server == side else { return } } else { guard lastHitter != side else { return } }
        p.swingHit = true

        let isHuman = side > 0 && !botControlsPlayer
        var quality: Float = 0.8
        if isHuman {                                   // timing rating: swing phase and racket distance vs ideal at contact
            let ideal: Float = serving ? 0.5 : 0.45
            let phaseErr = min(abs(p.swingProgress - ideal) / 0.4, 1)
            let distErr = min(simd_distance(ball.position, p.racketPoint) / (Player.reach * 0.9), 1)
            quality = 1 - phaseErr * 0.6 - distErr * 0.4
            let label = quality >= 0.85 ? "PERFECT" : (quality >= 0.65 ? "GOOD" : (quality >= 0.45 ? "OK" : (p.swingProgress > ideal ? "LATE" : "EARLY")))
            let shotName = (serving ? ShotType.topspin : p.shot).name
            lastEvent = "\(label)  \(shotName)"
            if quality >= 0.85 { crowdExcitement = max(crowdExcitement, 0.35) }
        }
        let shot: ShotType = serving ? .topspin : p.shot
        let plan = planShot(side: side, from: ball.position, shot: shot, serving: serving, isHuman: isHuman, playerX: p.position.x, quality: quality)
        ball.velocity = plan.velocity
        ball.spin = plan.spin
        let kmh = simd_length(ball.velocity) * 3.6
        shake = max(shake, simd_clamp((kmh - 70) / 90, 0, 1) * (isHuman ? 1.0 : 0.6))
        shotTypeCounts[shot.rawValue] += 1; lastShotType = shot
        events.append(.hit(side: side, speed: kmh, quality: quality, shot: shot, position: ball.position))
        ball.bounces = 0; ball.bouncesSinceHit = 0
        lastHitter = side; shotCount += 1; totalHits += 1
        phase = .rally
        if isHuman { lastEvent += String(format: " · %.0f km/h", simd_length(ball.velocity) * 3.6) }
    }

    struct ShotPlan { var velocity: float3; var spin: float3 }

    /// Decides pace, direction, arc and spin for a shot. Shots land short of the ballistic target because of drag, and spin changes
    /// that (topspin dives, backspin floats), so each type has its own aim calibration. `quality` (1 = perfect timing) scales
    /// pace and accuracy for the human player.
    func planShot(side: Float, from: float3, shot: ShotType, serving: Bool, isHuman: Bool, playerX: Float, quality: Float) -> ShotPlan {
        let dirZ = -side
        // Drag also compresses lateral spread by about half, so aim points are scaled up. The human's aim input is capped at ±6.
        let aim = isHuman ? humanAimX * 6.0 : (rand() - 0.5) * 11.0
        var targetX = simd_clamp(-playerX * 0.4 + aim, -7, 7)
        if serving { targetX = -serveSideSign * (1.2 + rand() * 2.2) + (isHuman ? humanAimX * -serveSideSign * 0.5 : 0) }   // diagonal service box
        var depth: Float = serving ? 7.0 + rand() * 1.8 : (isHuman ? 8.5 + rand() * 5.5 : 7.5 + rand() * 9.0)
        var desired: Float = serving ? 31 : 25 + rand() * 7
        var netMargin: Float = 0.7, spinAmount: Float = 180
        switch shot {
        case .topspin: break
        case .slice: desired *= 0.80; depth *= 0.42; targetX *= 0.8; netMargin = 0.5; spinAmount = -110     // backspin lift floats the ball: aim much shorter
        case .lob: desired = 16; depth = 9.0 + rand() * 2.5; targetX *= 0.7; netMargin = 3.4; spinAmount = 40   // high and deep
        case .drop: desired = 12.0; depth = 2.2 + rand() * 1.6; targetX *= 0.45; netMargin = 0.4; spinAmount = -90   // short, dying backspin
        }
        if isHuman {
            desired *= 0.92 + 0.14 * quality
            targetX += (rand() - 0.5) * 2 * (1 - quality) * 2.5
            depth += (rand() - 0.5) * 2 * (1 - quality) * 2.0
        }
        let to = float3(targetX, Ball.radius, dirZ * max(depth, 1.5))
        let flat = float3(to.x - from.x, 0, to.z - from.z)
        let d = simd_length(flat)
        // Fastest shot (<= desired) that lands on target and clears the net with margin for drag sag (ballistic estimate).
        var speed = desired, vy: Float = 0
        var s2 = desired
        while s2 >= 7 {
            let t = d / s2
            let v = (to.y - from.y + 0.5 * BallPhysics.gravity * t * t) / t
            let tNet = abs(from.z) / max(0.01, s2 * abs(flat.z) / d)
            let yNet = from.y + v * tNet - 0.5 * BallPhysics.gravity * tNet * tNet
            speed = s2; vy = v
            if yNet >= Court.netHeightCenter + netMargin { break }   // margin covers drag sag
            s2 -= 0.5
        }
        let dir = simd_normalize(flat)
        return ShotPlan(velocity: dir * speed + float3(0, vy, 0), spin: simd_normalize(simd_cross(float3(0, 1, 0), dir)) * spinAmount)
    }
}
