import simd

/// Opponent brain: predicts where the ball will be hittable, moves there, recovers to a home position, and times swings.
struct AIController {
    var maxSpeed: Float = 5.0
    /// Lateral prediction error in metres (larger = weaker opponent).
    var errorMagnitude: Float = 1.1
    private var desired: float3? = nil
    private var thinkTimer: Float = 0
    private var rng: UInt64 = 0x2545F4914F6CDD1D

    private mutating func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng % 10_000) / 10_000
    }

    struct Command { var dir = float3.zero; var swing = false; var shot = ShotType.topspin }

    mutating func control(me: Player, game: GameState, dt: Float) -> Command {
        var cmd = Command()
        let side = me.side
        let b = game.ball
        let home = float3(0, 0, side * 11.6)
        thinkTimer -= dt

        switch game.phase {
        case .pointOver:
            desired = nil
        case .serveReady:
            desired = nil
            if game.server == side && game.timer > 1.2 { cmd.swing = true }   // toss
        case .tossed:
            desired = nil
            if game.server == side && !me.isSwinging && b.velocity.y < 0 && b.position.y < 3.0 { cmd.swing = true }
        case .rally:
            let incoming = game.lastHitter == -side
            if incoming {
                if thinkTimer <= 0 || desired == nil {
                    thinkTimer = 0.12
                    desired = predictIntercept(ball: b, me: me).map { p in
                        let err = (rand() - 0.5) * 2 * errorMagnitude
                        // Pick whichever side (forehand/backhand) needs less running to meet the ball.
                        let fh = p - me.racketOffset(backhand: false) + me.right * err
                        let bh = p - me.racketOffset(backhand: true) + me.right * err
                        return simd_distance(fh, me.position) <= simd_distance(bh, me.position) ? fh : bh
                    }
                }
                if let d = desired, b.bouncesSinceHit >= 1 || abs(b.position.z) < 2 {
                    var t = d
                    t.x = simd_clamp(t.x, -7.4, 7.4)
                    t.z = side > 0 ? simd_clamp(t.z, 1.0, 14.8) : simd_clamp(t.z, -14.8, -1.0)
                    cmd.dir = steer(from: me.position, to: t)
                } else {
                    cmd.dir = steer(from: me.position, to: home)
                }
                let toBall = min(simd_distance(b.position, me.racketPoint(backhand: false)), simd_distance(b.position, me.racketPoint(backhand: true)))
                if !me.isSwinging && b.bouncesSinceHit >= 1 && toBall < 2.4 && b.position.y < 2.3
                    && b.position.z * side > 0 && b.velocity.z * side > -1 {
                    cmd.swing = true
                    // Mix up the shots: drop shot when the opponent is deep, lob when they are at the net, otherwise mostly topspin.
                    let other = side < 0 ? game.player : game.opponent
                    let oppDepth = abs(other.position.z), roll = rand()
                    if oppDepth > 9.5 && roll < 0.12 { cmd.shot = .drop }
                    else if oppDepth < 7 && roll < 0.35 { cmd.shot = .lob }
                    else if roll < 0.20 { cmd.shot = .slice }
                    else if roll > 0.95 { cmd.shot = .lob }
                    else if roll > 0.90 { cmd.shot = .drop }
                }
            } else {
                desired = nil
                cmd.dir = steer(from: me.position, to: home)
            }
        }
        if game.phase == .pointOver || (game.phase == .serveReady) { cmd.dir = .zero }
        return cmd
    }

    private func steer(from: float3, to: float3) -> float3 {
        var d = to - from; d.y = 0
        let len = simd_length(d)
        if len < 0.12 { return .zero }
        return d / len * min(1, len / 1.2)
    }

    /// Forward-simulates a copy of the ball; returns where it will be after its bounce on `me`'s side, at hitting height.
    private func predictIntercept(ball: Ball, me: Player) -> float3? {
        var q = ball
        var bounced = q.bouncesSinceHit >= 1
        var last: float3? = nil
        let dt: Float = 1.0 / 120.0
        for _ in 0..<(120 * 3) {
            let e = BallPhysics.step(&q, dt: dt)
            if case .bounce(let p) = e {
                if p.z * me.side <= 0 { return nil }          // lands on the other side (net / own error): don't chase
                bounced = true
            }
            if bounced {
                last = q.position
                if q.velocity.y <= 0 && q.position.y < 1.3 { return q.position }
            }
            if abs(q.position.z) > 16 { break }
        }
        return last
    }
}
