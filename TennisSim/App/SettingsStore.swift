import Foundation
import simd

/// Playing surface: changes court/surround colours and texture, and the ball's bounce.
enum CourtSurface: Int, CaseIterable {
    case hard = 0, clay, grass
    var name: String { ["Hard Court", "Clay Court", "Grass Court"][rawValue] }
    var blurb: String { ["Blue acrylic · fast, true", "Red clay · slow, high", "Natural grass · skiddy, low"][rawValue] }
    /// Ball bounce: (restitution, horizontal speed kept per bounce).
    var bounce: (Float, Float) { [(0.74, 0.78), (0.78, 0.66), (0.66, 0.86)][rawValue] }
    var courtColor: float4 { [float4(0.14, 0.32, 0.62, 1), float4(0.70, 0.30, 0.15, 1), float4(0.24, 0.49, 0.16, 1)][rawValue] }
    var surroundColor: float4 { [float4(0.12, 0.36, 0.27, 1), float4(0.60, 0.25, 0.13, 1), float4(0.20, 0.43, 0.14, 1)][rawValue] }
    /// Selected surface for the running game (set from the front menu; applied to rendering and ball physics).
    nonisolated(unsafe) static var current: CourtSurface = .hard { didSet { BallPhysics.setSurface(current.bounce) } }
}

/// User settings persisted in UserDefaults.
enum SettingsStore {
    private static let d = UserDefaults.standard
    static var difficulty: Difficulty {
        get { Difficulty(rawValue: d.object(forKey: "difficulty") as? Int ?? 1) ?? .medium }
        set { d.set(newValue.rawValue, forKey: "difficulty") }
    }
    static var followCamera: Bool {
        get { d.bool(forKey: "followCamera") }
        set { d.set(newValue, forKey: "followCamera") }
    }
    static var showStats: Bool {
        get { d.object(forKey: "showStats") as? Bool ?? true }
        set { d.set(newValue, forKey: "showStats") }
    }
    /// Fraction of display resolution rendered before MetalFX upscaling (Metal 4 path): 1.0, 0.75 or 0.5.
    static var renderScale: Float {
        get { d.object(forKey: "renderScale") as? Float ?? 0.75 }
        set { d.set(newValue, forKey: "renderScale") }
    }
    static var courtSurface: CourtSurface {
        get { CourtSurface(rawValue: d.object(forKey: "courtSurface") as? Int ?? 0) ?? .hard }
        set { d.set(newValue.rawValue, forKey: "courtSurface") }
    }
    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }
}
