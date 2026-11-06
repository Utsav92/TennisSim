import simd

/// Skeleton joints driven by Euler angles (radians; applied as Ry·Rx·Rz). Limbs hang along -Y, so +X pitch swings forward.
enum Joint: Int, CaseIterable {
    case root, spine, head, shoulderR, elbowR, wristR, shoulderL, elbowL, hipR, kneeR, hipL, kneeL
    static let upperBody: [Joint] = [.spine, .head, .shoulderR, .elbowR, .wristR, .shoulderL, .elbowL]
}

struct Pose {
    var angles = [float3](repeating: .zero, count: Joint.allCases.count)
    subscript(_ j: Joint) -> float3 {
        get { angles[j.rawValue] }
        set { angles[j.rawValue] = newValue }
    }
    static func lerp(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
        var r = a
        for i in 0..<a.angles.count { r.angles[i] = a.angles[i] + (b.angles[i] - a.angles[i]) * t }
        return r
    }
}

private func smooth(_ t: Float) -> Float { let x = simd_clamp(t, 0, 1); return x * x * (3 - 2 * x) }

/// Upper-body keyframes: (normalised time, [spine, head, shoulderR, elbowR, wristR, shoulderL, elbowL]).
typealias Key = (t: Float, a: [float3])
func k(_ t: Float, _ spine: float3, _ head: float3, _ shR: float3, _ elR: Float, _ wrR: Float, _ shL: float3, _ elL: Float) -> Key {
    (t, [spine, head, shR, float3(elR, 0, 0), float3(wrR, 0, 0), shL, float3(elL, 0, 0)])
}

enum SwingKind { case forehand, backhand, overhead }

enum Clips {
    /// Right-handed forehand: ready → unit turn and backswing → contact (~0.45) → follow-through across the body.
    static let forehand: [Key] = [
        k(0.00, float3(-0.08, 0, 0),  float3(0, 0, 0),   float3(0.35, -0.2, 0),  1.1, 0.75, float3(0.3, 0.3, 0),   1.0),
        k(0.28, float3(-0.05, -0.85, 0), float3(0, 0.6, 0), float3(0.35, -0.95, 0), 0.9, 0.2, float3(0.9, 0.8, 0),   0.6),
        k(0.45, float3(-0.10, -0.25, 0), float3(0, 0.25, 0), float3(1.15, -0.55, 0), 0.35, 0.0, float3(0.7, 0.9, 0),  0.5),
        k(0.70, float3(-0.10, 0.55, 0),  float3(0, -0.2, 0), float3(1.1, 0.5, 0),    1.1, 0.4, float3(0.4, 0.4, 0),   0.8),
        k(1.00, float3(-0.08, 0.25, 0),  float3(0, 0, 0),    float3(0.6, 0.2, 0),    1.2, 0.7, float3(0.3, 0.3, 0),   1.0),
    ]
    /// Overhead serve: trophy pose with tossing arm raised → racket arm extends up at contact (~0.5) → follow-through.
    static let serve: [Key] = [
        k(0.00, float3(-0.08, 0, 0),  float3(0, 0, 0),    float3(0.35, -0.2, 0), 1.1, 0.75, float3(0.3, 0.3, 0),   1.0),
        k(0.25, float3(0.10, -0.6, 0), float3(-0.4, 0.3, 0), float3(1.2, -1.0, 0), 1.9, 0.5,  float3(2.7, 0.2, 0),   0.1),
        k(0.50, float3(-0.15, -0.1, 0), float3(-0.5, 0, 0),  float3(2.65, -0.35, 0), 0.05, 0.0, float3(1.0, 0.4, 0), 1.0),
        k(0.75, float3(-0.30, 0.5, 0), float3(0, -0.2, 0),   float3(1.3, 0.5, 0),   0.6, 0.3,  float3(0.5, 0.3, 0),  0.9),
        k(1.00, float3(-0.08, 0.2, 0), float3(0, 0, 0),      float3(0.5, 0.1, 0),   1.2, 0.7,  float3(0.3, 0.3, 0),  1.0),
    ]

    /// One-handed backhand (right-handed player): unit turn to the left, racket across the body, contact on the left, follow-through up and across.
    static let backhand: [Key] = [
        k(0.00, float3(-0.08, 0, 0),    float3(0, 0, 0),     float3(0.35, -0.2, 0),   1.1, 0.75, float3(0.3, 0.3, 0),   1.0),
        k(0.28, float3(-0.05, 0.9, 0),  float3(0, -0.6, 0),  float3(0.95, 0.15, 0),   0.8, 0.3,  float3(0.9, -0.5, 0),  0.6),
        k(0.45, float3(-0.10, 0.25, 0), float3(0, -0.3, 0),  float3(1.25, 0.8, 0),    0.3, 0.0,  float3(0.8, -0.7, 0),  0.5),
        k(0.70, float3(-0.10, -0.55, 0), float3(0, 0.3, 0),  float3(1.55, -0.55, 0),  0.7, 0.3,  float3(0.6, -0.4, 0),  0.7),
        k(1.00, float3(-0.08, -0.2, 0), float3(0, 0, 0),     float3(0.6, -0.1, 0),    1.2, 0.7,  float3(0.3, 0.3, 0),   1.0),
    ]

    static func sample(_ keys: [Key], _ u: Float) -> [float3] {
        let u = simd_clamp(u, 0, 1)
        var i = 0
        while i < keys.count - 2 && u > keys[i + 1].t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let f = smooth((u - a.t) / max(b.t - a.t, 1e-4))
        return zip(a.a, b.a).map { $0 + ($1 - $0) * f }
    }
}

/// Blends locomotion (idle ↔ run by smoothed speed) with a layered upper-body swing whose weight ramps in and out,
/// so state changes cross-fade instead of popping.
struct Animator {
    private(set) var pose = Pose()
    private var smoothSpeed: Float = 0
    private var smoothLean = float2.zero
    private var phase: Float = 0
    private var time: Float = 0
    private(set) var swingWeight: Float = 0

    /// - Parameters:
    ///   - localVelocity: velocity in the character's frame (x = right, y = forward), m/s.
    ///   - swing: nil when idle, otherwise normalised progress 0…1 and whether it is an overhead (serve) swing.
    mutating func update(dt: Float, localVelocity: float2, maxSpeed: Float, swing: (progress: Float, kind: SwingKind)?) {
        time += dt
        let speed = simd_clamp(simd_length(localVelocity) / maxSpeed, 0, 1)
        let k = 1 - expf(-9 * dt)
        smoothSpeed += (speed - smoothSpeed) * k
        smoothLean += (localVelocity / maxSpeed - smoothLean) * k
        phase += dt * (4.0 + 7.5 * smoothSpeed) * (smoothSpeed > 0.02 ? 1 : 0.2)

        // --- locomotion: idle ready-stance blended with the run cycle ---
        let s = smoothSpeed
        var loco = Pose()
        let breath = sinf(time * 2.0) * 0.015
        let swR = sinf(phase), swL = sinf(phase + .pi)
        let bendR = max(0, cosf(phase)), bendL = max(0, cosf(phase + .pi))
        loco[.root] = float3(-0.06 - 0.20 * smoothLean.y * 1.0, 0, -0.14 * smoothLean.x)
        loco[.spine] = float3(-0.08 + breath, 0, 0)
        loco[.head] = float3(0.05, 0, 0)
        loco[.hipR] = float3(0.30 + 0.75 * s * swR, 0, 0)
        loco[.hipL] = float3(0.30 + 0.75 * s * swL, 0, 0)
        loco[.kneeR] = float3(-(0.55 + 1.0 * s * bendR), 0, 0)
        loco[.kneeL] = float3(-(0.55 + 1.0 * s * bendL), 0, 0)
        loco[.shoulderR] = float3(0.35 - 0.5 * s * swR, -0.2, 0)
        loco[.elbowR] = float3(1.1 + 0.2 * s, 0, 0)
        loco[.wristR] = float3(0.75, 0, 0)
        loco[.shoulderL] = float3(0.3 + 0.6 * s * swR, 0.3, 0)
        loco[.elbowL] = float3(1.0 + 0.3 * s, 0, 0)

        // --- swing layer ---
        var target = swing != nil ? 1 : Float(0)
        var result = loco
        if let sw = swing {
            let u = sw.progress
            let weight = smooth(u / 0.10) * (1 - smooth((u - 0.78) / 0.22))     // blend in, hold, blend out
            target = weight
            let keys: [Key]
            switch sw.kind { case .overhead: keys = Clips.serve; case .backhand: keys = Clips.backhand; case .forehand: keys = Clips.forehand }
            let a = Clips.sample(keys, u)
            for (j, v) in zip(Joint.upperBody, a) { result[j] = loco[j] + (v - loco[j]) * weight }
            // Legs: load into the shot (extra knee bend, front-foot lunge) timed to the stroke.
            let lunge = sinf(u * .pi) * (sw.kind == .overhead ? 0.0 : 0.25)
            result[.hipL] += float3(lunge, 0, 0); result[.kneeL] += float3(-lunge, 0, 0)
        }
        swingWeight = target
        pose = result
    }

    /// Adds a head turn/tilt on top of the animated pose (used to follow the ball).
    mutating func addHeadLook(yaw: Float, pitch: Float) { pose[.head] += float3(pitch, yaw, 0) }
}

/// Forward kinematics for the character: Pose → world transforms of each Blender-authored part.
enum CharacterRig {
    static let scale: Float = 0.96
    static let hipY: Float = 0.98
    static let soleOffset: Float = 0.081          // ankle pivot → sole (from shoe.obj)

    static func euler(_ e: float3) -> float4x4 { .rotationY(e.y) * .rotationX(e.x) * .rotationZ(e.z) }

    struct Result { var parts: [(PartID, float4x4)]; var racketHead: float3; var frames: [float4x4] }   // frames: 15 skeleton frames in AthleteModel bone order

    static func evaluate(world: float4x4, pose: Pose) -> Result {
        func build(_ lift: Float) -> (Result, Float) {
            let T = float4x4.translation
            let hips = T(float3(0, hipY + lift, 0)) * euler(pose[.root])
            let spine = hips * euler(pose[.spine])
            let neck = spine * T(float3(0, 0.62, 0)) * euler(pose[.head])
            let shR = spine * T(float3(0.235, 0.54, 0)) * euler(pose[.shoulderR])
            let elR = shR * T(float3(0, -0.30, 0)) * euler(pose[.elbowR])
            let wrR = elR * T(float3(0, -0.27, 0)) * euler(pose[.wristR])
            let shL = spine * T(float3(-0.235, 0.54, 0)) * euler(pose[.shoulderL])
            let elL = shL * T(float3(0, -0.30, 0)) * euler(pose[.elbowL])
            let wrL = elL * T(float3(0, -0.27, 0))
            let rk = wrR * T(float3(0, -0.045, 0))                      // racket grip sits in the fist
            let hpR = hips * T(float3(0.095, -0.02, 0)) * euler(pose[.hipR])
            let knR = hpR * T(float3(0, -0.45, 0)) * euler(pose[.kneeR])
            let anR = knR * T(float3(0, -0.43, 0))
            let hpL = hips * T(float3(-0.095, -0.02, 0)) * euler(pose[.hipL])
            let knL = hpL * T(float3(0, -0.45, 0)) * euler(pose[.kneeL])
            let anL = knL * T(float3(0, -0.43, 0))
            let parts: [(PartID, float4x4)] = [
                (.shorts, hips), (.torso, spine), (.head, neck), (.hair, neck),
                (.upperArm, shR), (.foreArm, elR), (.hand, wrR),
                (.racketHandle, rk), (.racketFrame, rk), (.racketStrings, rk),
                (.upperArm, shL), (.foreArm, elL), (.hand, wrL),
                (.thigh, hpR), (.calf, knR), (.shoe, anR),
                (.thigh, hpL), (.calf, knL), (.shoe, anL)]
            let headLocal = rk * float4(0, -0.46, 0, 1)                    // string-bed centre
            let minAnkle = min(anR.columns.3.y, anL.columns.3.y)
            let frames = [hips, spine, neck, shR, elR, wrR, shL, elL, wrL, hpR, knR, anR, hpL, knL, anL]
            return (Result(parts: parts, racketHead: float3(headLocal.x, headLocal.y, headLocal.z), frames: frames), minAnkle)
        }
        let (_, minAnkle) = build(0)
        let lift = soleOffset - minAnkle                                   // plant the lowest foot on the ground
        let (r, _) = build(lift)
        let s = float4x4.scale(float3(repeating: scale))
        let m = world * s
        var out = Result(parts: r.parts.map { ($0.0, m * $0.1) }, racketHead: .zero, frames: r.frames)
        let h = m * float4(r.racketHead, 1)
        out.racketHead = float3(h.x, h.y, h.z)
        return out
    }

    /// Skinning palette (bone order of the HUM asset): maps rest-pose vertices to the posed skeleton, in character space
    /// (the model matrix adds world placement and scale). Limbs modelled in an A-pose are straightened by each bone's `rotZ`.
    /// Eye bones (15, 16) rotate about the eye centres in the head's rest space to look at the ball.
    static func palette(frames: [float4x4], model: AthleteModel, expression: Expression) -> [float4x4] {
        var out: [float4x4] = []
        out.reserveCapacity(model.boneCount)
        for i in 0..<15 {
            let b = model.bones[i]
            out.append(frames[i] * .rotationZ(b.rotZ) * .translation(-b.joint))
        }
        let headM = out[2]
        for i in 15..<model.boneCount {
            let j = model.bones[i].joint
            out.append(headM * .translation(j) * .rotationY(expression.gazeYaw) * .rotationX(expression.gazePitch) * .translation(-j))
        }
        return out
    }
}
