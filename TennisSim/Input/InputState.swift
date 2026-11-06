import simd
import GameController

struct InputState {
    var move = SIMD2<Float>(0, 0)   // x: right, y: forward (toward net)
    var swingPressed = false        // edge-triggered
    var shot = ShotType.topspin     // shot chosen by the button that triggered the swing
    var resetPressed = false        // edge-triggered
}

/// Aggregates keyboard (fed by the view) and the first connected game controller.
final class InputManager {
    private var keys = Set<UInt16>()
    private var swingEdge = false, resetEdge = false
    private var shotEdge = ShotType.topspin
    private var lastPad = false, lastMenu = false, lastB = false, lastY = false, lastX = false
    var onMenu: (() -> Void)?
    private var touchMove = SIMD2<Float>(0, 0)
    func setTouchMove(_ v: SIMD2<Float>) { touchMove = v }
    func touchSwing(_ shot: ShotType = .topspin) { swingEdge = true; shotEdge = shot }

    // macOS virtual key codes
    static let kW: UInt16 = 13, kA: UInt16 = 0, kS: UInt16 = 1, kD: UInt16 = 2
    static let kLeft: UInt16 = 123, kRight: UInt16 = 124, kDown: UInt16 = 125, kUp: UInt16 = 126
    static let kSpace: UInt16 = 49, kR: UInt16 = 15, kJ: UInt16 = 38, kK: UInt16 = 40, kL: UInt16 = 37

    func keyDown(_ code: UInt16, isRepeat: Bool) {
        if !isRepeat {
            if code == Self.kSpace { swingEdge = true; shotEdge = .topspin }
            if code == Self.kJ { swingEdge = true; shotEdge = .slice }
            if code == Self.kK { swingEdge = true; shotEdge = .lob }
            if code == Self.kL { swingEdge = true; shotEdge = .drop }
            if code == Self.kR { resetEdge = true }
        }
        keys.insert(code)
    }
    func keyUp(_ code: UInt16) { keys.remove(code) }

    func poll() -> InputState {
        var s = InputState()
        var x: Float = 0, y: Float = 0
        if keys.contains(Self.kA) || keys.contains(Self.kLeft) { x -= 1 }
        if keys.contains(Self.kD) || keys.contains(Self.kRight) { x += 1 }
        if keys.contains(Self.kW) || keys.contains(Self.kUp) { y += 1 }
        if keys.contains(Self.kS) || keys.contains(Self.kDown) { y -= 1 }
        if simd_length(touchMove) > 0.05 { x = touchMove.x; y = touchMove.y }
        var pressed = false
        if let pad = GCController.controllers().first?.extendedGamepad {
            let st = pad.leftThumbstick
            if abs(st.xAxis.value) > 0.15 { x = st.xAxis.value }
            if abs(st.yAxis.value) > 0.15 { y = st.yAxis.value }
            pressed = pad.buttonA.isPressed
            if pad.buttonB.isPressed && !lastB { swingEdge = true; shotEdge = .slice }
            if pad.buttonY.isPressed && !lastY { swingEdge = true; shotEdge = .lob }
            if pad.buttonX.isPressed && !lastX { swingEdge = true; shotEdge = .drop }
            lastB = pad.buttonB.isPressed; lastY = pad.buttonY.isPressed; lastX = pad.buttonX.isPressed
            let menu = pad.buttonMenu.isPressed
            if menu && !lastMenu { onMenu?() }
            lastMenu = menu
        }
        if pressed && !lastPad { swingEdge = true; shotEdge = .topspin }
        lastPad = pressed
        var m = SIMD2<Float>(x, y)
        if simd_length(m) > 1 { m = simd_normalize(m) }
        s.move = m
        s.swingPressed = swingEdge; s.resetPressed = resetEdge; s.shot = shotEdge
        swingEdge = false; resetEdge = false
        return s
    }
}
