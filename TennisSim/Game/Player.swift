import simd

struct Player {
    /// +1 = near end (+z, human), -1 = far end (-z, opponent).
    var side: Float
    var position: float3
    var facing: Float                // yaw; 0 faces -z (toward the net), π faces +z
    var velocity = float3.zero
    var swingTime: Float = 10        // seconds since swing started
    var swingLift: Float = 0.4       // overhead reach: 1.6 for serves, small for groundstrokes
    var swingHit = false
    var backhand = false             // racket on the left side for this swing
    var shot: ShotType = .topspin    // chosen when the swing starts
    var runPhase: Float = 0
    var anim = Animator()
    var expression = Expression()
    private var blinkClock: Float = 1.5
    private var blinkAnim: Float = -1          // < 0: not blinking; else seconds into the blink
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    /// Raised by the game when this player wins a point; fades over a couple of seconds.
    var smileTarget: Float = 0

    static let accel: Float = 30.0
    static let swingDuration: Float = 0.35
    static let reach: Float = 1.9

    init(side: Float) {
        self.side = side
        position = float3(0, 0, side * 11.5)
        facing = side > 0 ? 0 : .pi
    }

    var isSwinging: Bool { swingTime < Player.swingDuration }
    var swingProgress: Float { min(1, swingTime / Player.swingDuration) }
    var right: float3 { float3(cosf(facing), 0, -sinf(facing)) }
    var forward: float3 { float3(-sinf(facing), 0, -cosf(facing)) }
    /// Horizontal offset from body to racket head at rest.
    var racketOffset: float3 { racketOffset(backhand: backhand) }
    func racketOffset(backhand bh: Bool) -> float3 { right * (bh ? -0.8 : 0.8) + forward * 0.5 }

    /// Racket head position in world space.
    var worldMatrix: float4x4 { .translation(position) * .rotationY(facing) }
    var racketPoint: float3 { racketPoint(backhand: backhand) }
    func racketPoint(backhand bh: Bool) -> float3 {
        let lift: Float = isSwinging ? swingLift * sinf(swingProgress * .pi) : 0
        return position + float3(0, 1.0 + lift, 0) + racketOffset(backhand: bh)
    }

    mutating func update(worldDir: float3, maxSpeed: Float, dt: Float, lookAt: float3? = nil) {
        let target = worldDir * maxSpeed
        let dv = target - velocity
        let maxDv = Player.accel * dt
        velocity += simd_length(dv) > maxDv ? simd_normalize(dv) * maxDv : dv
        position += velocity * dt
        position.x = simd_clamp(position.x, -7.5, 7.5)
        position.z = side > 0 ? simd_clamp(position.z, 0.8, 15.0) : simd_clamp(position.z, -15.0, -0.8)
        runPhase += simd_length(velocity) * dt * 1.6
        swingTime += dt
        let local = float2(simd_dot(velocity, right), simd_dot(velocity, forward))
        anim.update(dt: dt, localVelocity: local, maxSpeed: 7.0,
                    swing: isSwinging ? (swingProgress, swingLift > 1.0 ? .overhead : (backhand ? .backhand : .forehand)) : nil)
        updateFace(dt: dt, lookAt: lookAt)
    }

    mutating func startSwing(lift: Float, backhand bh: Bool = false, shot sh: ShotType = .topspin) {
        if !isSwinging { swingTime = 0; swingLift = lift; swingHit = false; backhand = bh; shot = sh }
    }

    private mutating func nextRandom() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng % 10_000) / 10_000
    }

    /// Blinks, effort/smile expressions and gaze toward `lookAt` (usually the ball).
    private mutating func updateFace(dt: Float, lookAt: float3?) {
        // blink: a quick triangular close/open every 2–5 s
        if blinkAnim < 0 {
            blinkClock -= dt
            if blinkClock <= 0 { blinkAnim = 0 }
            expression.blink = 0
        } else {
            blinkAnim += dt
            let t = blinkAnim / 0.16
            expression.blink = t >= 1 ? 0 : 1 - abs(2 * t - 1)
            if t >= 1 { blinkAnim = -1; blinkClock = 2.0 + nextRandom() * 3.0 }
        }
        // effort grimace builds through the stroke; smile after a won point
        let effortTarget: Float = isSwinging ? (0.4 + 0.6 * sinf(swingProgress * .pi)) * (swingLift > 1.0 ? 1.0 : 0.8) : 0
        expression.effort += (effortTarget - expression.effort) * (1 - expf(-14 * dt))
        smileTarget = max(0, smileTarget - 0.35 * dt)
        expression.smile += (smileTarget - expression.smile) * (1 - expf(-6 * dt))
        // gaze: head takes ~55 % of the turn, eyes the rest
        var yaw: Float = 0, pitch: Float = 0
        if let target = lookAt {
            let head = position + float3(0, 1.62, 0)
            let d = target - head
            let local = float3(simd_dot(d, right), d.y, simd_dot(d, forward))
            yaw = -atan2f(local.x, max(local.z, 0.2))
            pitch = atan2f(local.y, max(simd_length(float2(local.x, local.z)), 0.2))
        }
        let headYaw = simd_clamp(yaw * 0.55, -0.7, 0.7), headPitch = simd_clamp(pitch * 0.5, -0.35, 0.35)
        anim.addHeadLook(yaw: headYaw, pitch: headPitch)
        expression.gazeYaw = simd_clamp(yaw - headYaw, -0.5, 0.5)
        expression.gazePitch = simd_clamp(pitch - headPitch, -0.3, 0.3)
    }
}
