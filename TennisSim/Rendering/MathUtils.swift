import simd

typealias float3 = SIMD3<Float>
typealias float4 = SIMD4<Float>

extension float4x4 {
    static func translation(_ t: float3) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = float4(t, 1)
        return m
    }
    static func scale(_ s: float3) -> float4x4 {
        float4x4(diagonal: float4(s, 1))
    }
    static func rotationY(_ a: Float) -> float4x4 {
        let c = cosf(a), s = sinf(a)
        return float4x4(columns: (float4(c, 0, -s, 0), float4(0, 1, 0, 0), float4(s, 0, c, 0), float4(0, 0, 0, 1)))
    }
    static func rotationZ(_ a: Float) -> float4x4 {
        let c = cosf(a), s = sinf(a)
        return float4x4(columns: (float4(c, s, 0, 0), float4(-s, c, 0, 0), float4(0, 0, 1, 0), float4(0, 0, 0, 1)))
    }
    static func rotationX(_ a: Float) -> float4x4 {
        let c = cosf(a), s = sinf(a)
        return float4x4(columns: (float4(1, 0, 0, 0), float4(0, c, s, 0), float4(0, -s, c, 0), float4(0, 0, 0, 1)))
    }
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tanf(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(columns: (float4(x, 0, 0, 0), float4(0, y, 0, 0), float4(0, 0, z, -1), float4(0, 0, z * near, 0)))
    }
    static func lookAt(eye: float3, target: float3, up: float3 = float3(0, 1, 0)) -> float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (float4(s.x, u.x, -f.x, 0), float4(s.y, u.y, -f.y, 0), float4(s.z, u.z, -f.z, 0),
                                  float4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}
