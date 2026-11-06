import Metal
import simd

/// Stadium bowl dimensions shared by the geometry builder (SceneBuilder) and the crowd placement (CrowdBuilder).
enum Stadium {
    static let tiers = 9
    static let tierDepth: Float = 1.5
    /// Tier `t`: distance of the end-stand strip centre (dz), side-stand strip centre (dx) and riser height (h).
    static func tier(_ t: Int) -> (dz: Float, dx: Float, h: Float) {
        let f = Float(t)
        return (Court.halfLength + 8.5 + f * tierDepth, Court.halfWidthDoubles + 7.5 + f * tierDepth, 1.0 + f)
    }
}

/// One seated spectator, mirrored by `struct Spectator` in Shaders.metal.
struct SpectatorInstance {
    var posYaw: SIMD4<Float>     // xyz = seat position, w = yaw (faces the court)
    var shirt: SIMD4<Float>      // rgb = shirt colour (sRGB), a = scale
    var misc: SIMD4<Float>       // x = phase, y = excitability, z = skin tone 0…1, w = hair colour 0…1
}

enum CrowdBuilder {
    /// Fills every stand strip with two rows of spectators (≈14 % empty seats), facing the court.
    static func instances() -> [SpectatorInstance] {
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Float {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Float(rng % 100_000) / 100_000
        }
        let palette: [SIMD3<Float>] = [
            [0.78, 0.10, 0.10], [0.10, 0.22, 0.65], [0.93, 0.93, 0.93], [0.95, 0.75, 0.10], [0.12, 0.45, 0.28],
            [0.10, 0.10, 0.12], [0.85, 0.35, 0.10], [0.55, 0.20, 0.60], [0.30, 0.65, 0.85], [0.80, 0.55, 0.60],
            [0.62, 0.62, 0.66], [0.40, 0.28, 0.18], [0.05, 0.30, 0.45], [0.88, 0.80, 0.62], [0.70, 0.12, 0.35], [0.18, 0.18, 0.40]]
        var out: [SpectatorInstance] = []
        func add(_ x: Float, _ y: Float, _ z: Float) {
            if rand() < 0.14 { return }
            let c = palette[Int(rand() * Float(palette.count)) % palette.count]
            let yaw = atan2f(x, z)                              // object -Z faces the court centre
            out.append(SpectatorInstance(posYaw: SIMD4(x, y, z, yaw),
                                         shirt: SIMD4(c.x * (0.8 + 0.4 * rand()), c.y * (0.8 + 0.4 * rand()), c.z * (0.8 + 0.4 * rand()), 0.9 + rand() * 0.22),
                                         misc: SIMD4(rand(), 0.35 + 0.65 * rand(), rand(), rand())))
        }
        let step: Float = 0.62
        for t in 0..<Stadium.tiers {
            let (dz, dx, h) = Stadium.tier(t)
            // End stands (±z): strips run along x.
            let halfX = dx + 1.5 - 0.5
            for s: Float in [-1, 1] {
                for rowOffset: Float in [-0.32, 0.32] {
                    var x = -halfX + rand() * 0.2
                    while x < halfX { add(x + (rand() - 0.5) * 0.12, h, s * (dz + rowOffset)); x += step }
                }
            }
            // Side stands (±x): strips run along z, between the end stands.
            let halfZ = dz - 0.75 - 0.4
            for s: Float in [-1, 1] {
                for rowOffset: Float in [-0.32, 0.32] {
                    var z = -halfZ + rand() * 0.2
                    while z < halfZ { add(s * (dx + rowOffset), h, z + (rand() - 0.5) * 0.12); z += step }
                }
            }
        }
        return out
    }

    static func buffer(device: MTLDevice) -> (MTLBuffer, Int)? {
        let list = instances()
        guard let b = device.makeBuffer(bytes: list, length: MemoryLayout<SpectatorInstance>.stride * list.count,
                                        options: .storageModeShared) else { return nil }
        return (b, list.count)
    }
}
