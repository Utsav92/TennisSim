import Metal
import Foundation
import simd

/// One mesh of the skinned athlete (body, eyes, hair, clothing…): interleaved 64-byte vertices + uint32 indices.
final class SkinnedPart {
    let name: String
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let vertexCount: Int
    let morphBuffer: MTLBuffer?          // 3 morph targets × vertexCount × float4 (body only)
    init(name: String, vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int, vertexCount: Int, morphBuffer: MTLBuffer?) {
        self.name = name; self.vertexBuffer = vertexBuffer; self.indexBuffer = indexBuffer
        self.indexCount = indexCount; self.vertexCount = vertexCount; self.morphBuffer = morphBuffer
    }
}

/// Binary "HUM1" asset produced by Tools/blender/make_athlete.py.
/// Vertex layout (64 B): pos f3, normal f3, tangent f3, joints u8×4, region u8 (+3 pad), pad f, weights f4.
final class AthleteModel {
    struct Bone { var name: String; var joint: float3; var rotZ: Float }
    let bones: [Bone]
    let parts: [String: SkinnedPart]
    static let vertexStride = 64

    var boneCount: Int { bones.count }
    func boneIndex(_ name: String) -> Int { bones.firstIndex { $0.name == name } ?? 0 }

    var allBuffers: [MTLAllocation] {
        parts.values.flatMap { p -> [MTLAllocation] in [p.vertexBuffer, p.indexBuffer] + (p.morphBuffer.map { [$0] } ?? []) }
    }

    init?(device: MTLDevice, url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 8,
              data.prefix(4) == Data("HUM1".utf8) else { return nil }
        let jsonLen = Int(data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard let meta = try? JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + jsonLen))) as? [String: Any],
              let boneList = meta["bones"] as? [[String: Any]], let partList = meta["parts"] as? [[String: Any]] else { return nil }
        let base = 8 + jsonLen + ((16 - (8 + jsonLen) % 16) % 16)
        bones = boneList.map { b in
            let j = (b["joint"] as? [Double]) ?? [0, 0, 0]
            return Bone(name: b["name"] as? String ?? "", joint: float3(Float(j[0]), Float(j[1]), Float(j[2])), rotZ: Float(b["rotZ"] as? Double ?? 0))
        }
        var built: [String: SkinnedPart] = [:]
        for p in partList {
            guard let name = p["name"] as? String, let vc = p["vertexCount"] as? Int, let ic = p["indexCount"] as? Int,
                  let vo = p["vertexOffset"] as? Int, let io = p["indexOffset"] as? Int else { return nil }
            let vBytes = vc * Self.vertexStride, iBytes = ic * 4
            guard base + io + iBytes <= data.count else { return nil }
            let vb = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + base + vo, length: vBytes, options: .storageModeShared) }
            let ib = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + base + io, length: iBytes, options: .storageModeShared) }
            var mb: MTLBuffer? = nil
            if let mo = p["morphOffset"] as? Int {
                let mBytes = vc * 16 * ((meta["morphs"] as? [String])?.count ?? 3)
                mb = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + base + mo, length: mBytes, options: .storageModeShared) }
            }
            guard let vb, let ib else { return nil }
            built[name] = SkinnedPart(name: name, vertexBuffer: vb, indexBuffer: ib, indexCount: ic, vertexCount: vc, morphBuffer: mb)
        }
        parts = built
    }
}

/// Facial expression state driven by gameplay (blink, smile, effort) and gaze toward the ball.
struct Expression {
    var blink: Float = 0, smile: Float = 0, effort: Float = 0
    var gazeYaw: Float = 0, gazePitch: Float = 0
    var vector: float4 { float4(blink, smile, effort, 0) }
}

/// What the renderer needs to draw one skinned character this frame.
struct SkinnedCharacterDraw {
    struct PartDraw {
        var part: SkinnedPart
        var material: Int            // 14 skin, 15 eye, 16 hair, 17 cloth
        var color: float4
        var accent: float4
        var cullBack: Bool = true
        var castsShadow: Bool = true
        var rough: Float = 0.6
        var spec: Float = 0.05
    }
    var palette: [float4x4]
    var prevPalette: [float4x4]
    var model: float4x4
    var prevModel: float4x4
    var morph: float4
    var parts: [PartDraw]
}
