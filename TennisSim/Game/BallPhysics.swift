import simd

/// Court dimensions in metres (ITF). Net plane is z = 0, +z is the player's end, y is up.
enum Court {
    static let halfLength: Float = 11.885
    static let halfWidthSingles: Float = 4.115
    static let halfWidthDoubles: Float = 5.485
    static let serviceLineZ: Float = 6.4
    static let netHeightCenter: Float = 0.914
    static let netHeightPost: Float = 1.07
    static let netHalfWidth: Float = 6.4
}

struct Ball {
    static let radius: Float = 0.0335
    static let mass: Float = 0.057
    var position = float3(0, 1, 0)
    var velocity = float3.zero
    /// Angular velocity (rad/s), world space.
    var spin = float3.zero
    var bounces = 0
    var bouncesSinceHit = 0
}

enum BallEvent { case bounce(float3), netHit, netCord, none }

/// Swift facade over the C++ simulation core (Sim/BallSim.cpp): gravity, quadratic drag, Magnus force, bounce, net.
enum BallPhysics {
    static let gravity: Float = 9.81
    static let dragK: Float = 0.0020      // per-metre drag coefficient (CdρA/2m, ~tennis ball)
    static let magnusK: Float = 0.0009    // lift per (ω×v), tuned for plausible topspin dip
    static let restitution: Float = 0.74
    static let tangentialKeep: Float = 0.78

    private static var params = BSParams(gravity: gravity, dragK: dragK, magnusK: magnusK, restitution: restitution,
                                         tangentialKeep: tangentialKeep, radius: Ball.radius)
    private static var court = BSCourt(halfLength: Court.halfLength, netHalfWidth: Court.netHalfWidth,
                                       netHeightCenter: Court.netHeightCenter, netHeightPost: Court.netHeightPost)

    static func setSurface(_ b: (Float, Float)) { params.restitution = b.0; params.tangentialKeep = b.1 }

    static func step(_ b: inout Ball, dt: Float) -> BallEvent {
        var c = BSBall(position: (b.position.x, b.position.y, b.position.z),
                       velocity: (b.velocity.x, b.velocity.y, b.velocity.z),
                       spin: (b.spin.x, b.spin.y, b.spin.z),
                       bounces: Int32(b.bounces), bouncesSinceHit: Int32(b.bouncesSinceHit))
        let e = BSStepBall(&c, dt, &params, &court)
        b.position = float3(c.position.0, c.position.1, c.position.2)
        b.velocity = float3(c.velocity.0, c.velocity.1, c.velocity.2)
        b.spin = float3(c.spin.0, c.spin.1, c.spin.2)
        b.bounces = Int(c.bounces); b.bouncesSinceHit = Int(c.bouncesSinceHit)
        switch e {
        case Int32(BS_EVENT_BOUNCE): return .bounce(b.position)
        case Int32(BS_EVENT_NET): return .netHit
        case Int32(BS_EVENT_NET_CORD): return .netCord
        default: return .none
        }
    }
}
