import Metal
import Foundation

/// Minimal Wavefront OBJ reader (v / vn / f with v//vn or v/vt/vn, polygons fan-triangulated), as exported by Blender.
enum OBJLoader {
    static func load(device: MTLDevice, url: URL) -> Mesh? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var pos: [float3] = [], nrm: [float3] = []
        var vertices: [Vertex] = [], indices: [UInt16] = []
        var cache: [String: UInt16] = [:]
        for line in text.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = t.first else { continue }
            switch tag {
            case "v" where t.count >= 4: pos.append(float3(Float(t[1])!, Float(t[2])!, Float(t[3])!))
            case "vn" where t.count >= 4: nrm.append(float3(Float(t[1])!, Float(t[2])!, Float(t[3])!))
            case "f":
                var face: [UInt16] = []
                for corner in t.dropFirst() {
                    let key = String(corner)
                    if let i = cache[key] { face.append(i); continue }
                    let c = corner.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vi = Int(c[0]), c.count == 3, let ni = Int(c[2]), vertices.count < 65535 else { return nil }
                    let i = UInt16(vertices.count)
                    vertices.append(Vertex(position: pos[vi - 1], normal: nrm[ni - 1]))
                    cache[key] = i; face.append(i)
                }
                for k in 1..<max(face.count - 1, 1) { indices += [face[0], face[k], face[k + 1]] }
            default: break
            }
        }
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }
        return Mesh(device: device, vertices: vertices, indices: indices)
    }
}

/// Body-part meshes authored in Blender (Tools/blender/make_assets.py), keyed by PartID.
enum PartID: Int, CaseIterable {
    case torso = 10, head, hair, upperArm, foreArm, thigh, calf, shoe, shorts, hand, racketFrame, racketHandle, racketStrings
    var file: String {
        ["torso", "head", "hair", "upperArm", "foreArm", "thigh", "calf", "shoe", "shorts", "hand",
         "racketFrame", "racketHandle", "racketStrings"][rawValue - 10]
    }
    static func loadAll(device: MTLDevice) -> [Int: Mesh] {
        var out: [Int: Mesh] = [:]
        for p in allCases {
            if let url = Bundle.main.url(forResource: p.file, withExtension: "obj"), let m = OBJLoader.load(device: device, url: url) {
                out[p.rawValue] = m
            } else { NSLog("Missing/invalid model asset: \(p.file).obj") }
        }
        return out
    }
}
