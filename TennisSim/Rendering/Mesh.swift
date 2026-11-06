import Metal
import simd

/// Tightly packed 24-byte vertex (6 floats) matching the vertex descriptor in Renderer.
struct Vertex {
    var px, py, pz, nx, ny, nz: Float
    init(position p: float3, normal n: float3) { px = p.x; py = p.y; pz = p.z; nx = n.x; ny = n.y; nz = n.z }
}

final class Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init(device: MTLDevice, vertices: [Vertex], indices: [UInt16]) {
        vertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count)!
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count)!
        indexCount = indices.count
    }

    static func unitBox(device: MTLDevice) -> Mesh {
        let faces: [(float3, float3, float3)] = [
            (float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1)), (float3(-1, 0, 0), float3(0, 1, 0), float3(0, 0, -1)),
            (float3(0, 1, 0), float3(0, 0, 1), float3(1, 0, 0)), (float3(0, -1, 0), float3(0, 0, -1), float3(1, 0, 0)),
            (float3(0, 0, 1), float3(0, 1, 0), float3(-1, 0, 0)), (float3(0, 0, -1), float3(0, 1, 0), float3(1, 0, 0))]
        var v: [Vertex] = [], idx: [UInt16] = []
        for (n, u, w) in faces {
            let b = UInt16(v.count)
            for (a, c) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                v.append(Vertex(position: (n + u * a + w * c) * 0.5, normal: n))
            }
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
        }
        return Mesh(device: device, vertices: v, indices: idx)
    }

    /// Unit-diameter sphere.
    static func unitSphere(device: MTLDevice, stacks: Int = 16, slices: Int = 24) -> Mesh {
        var v: [Vertex] = [], idx: [UInt16] = []
        for i in 0...stacks {
            let phi = Float.pi * Float(i) / Float(stacks)
            for j in 0...slices {
                let th = 2 * Float.pi * Float(j) / Float(slices)
                let n = float3(sinf(phi) * cosf(th), cosf(phi), sinf(phi) * sinf(th))
                v.append(Vertex(position: n * 0.5, normal: n))
            }
        }
        for i in 0..<stacks { for j in 0..<slices {
            let a = UInt16(i * (slices + 1) + j), b = a + UInt16(slices + 1)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        } }
        return Mesh(device: device, vertices: v, indices: idx)
    }
}
