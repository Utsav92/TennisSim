import simd

enum CameraMode: String { case broadcast = "Broadcast", follow = "Follow" }

struct BroadcastCamera {
    var eye = float3(0, 14, 24)
    var target = float3(0, 0, 0)
    var fov: Float = 0.62

    private(set) var shakeOffset = float3.zero
    var view: float4x4 { .lookAt(eye: eye + shakeOffset, target: target + shakeOffset * 0.5) }
    /// Hard hits shake the camera: a few millimetres to centimetres of high-frequency jitter that fades out.
    mutating func setShake(_ amount: Float, time t: Float) {
        let a = amount * amount * 0.07
        shakeOffset = float3(sinf(t * 71.0) + sinf(t * 43.0 + 1.3), sinf(t * 83.0 + 0.7) + sinf(t * 37.0), sinf(t * 59.0 + 2.1)) * a * 0.5
    }
    func projection(aspect: Float) -> float4x4 { .perspective(fovY: fov, aspect: aspect, near: 0.3, far: 1500) }

    mutating func update(mode: CameraMode, player: Player, ball: Ball, dt: Float, serveCam: Bool = false) {
        let k = 1 - expf(-4 * dt)
        var wantEye: float3, wantTarget: float3
        switch mode {
        case .broadcast where serveCam:                  // low and close behind the server, looking down the court
            wantEye = float3(player.position.x * 0.5, 2.7, player.position.z + 5.5)
            wantTarget = float3(player.position.x * 0.2, 1.3, -6)
        case .broadcast:
            wantEye = float3(player.position.x * 0.2, 9.5, 21.5 + player.position.z * 0.3)
            wantTarget = float3(player.position.x * 0.3, 0.5, 1.5 + ball.position.z * 0.2)
        case .follow:
            wantEye = player.position + float3(0, 3.2, 6.5)
            wantTarget = float3(ball.position.x * 0.5, 1, ball.position.z * 0.5 - 2)
        }
        eye += (wantEye - eye) * k
        target += (wantTarget - target) * k
    }
}
