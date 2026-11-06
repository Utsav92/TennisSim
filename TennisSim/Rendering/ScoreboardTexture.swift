import Metal
import CoreGraphics
import CoreText
import Foundation

/// Live LED-scoreboard texture. Redrawn with CoreText only when the displayed score changes.
final class ScoreboardTexture {
    static let width = 1024, height = 256
    let texture: MTLTexture
    private var lastKey = ""

    init?(device: MTLDevice) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        redraw(games: [0, 0], points: ["0", "0"], server: 1, tiebreak: false)
    }

    func update(game: GameState) {
        let key = "\(game.games)\(game.displayPoints)\(game.server)\(game.inTiebreak)"
        guard key != lastKey else { return }
        lastKey = key
        redraw(games: game.games, points: game.displayPoints, server: game.server, tiebreak: game.inTiebreak)
    }

    private func redraw(games: [Int], points: [String], server: Float, tiebreak: Bool) {
        let w = Self.width, h = Self.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(red: 0.02, green: 0.05, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 0.05, green: 0.12, blue: 0.35, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 2 - 3, width: w, height: 6))
            func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, rightAlign: Bool = false) {
                let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: rightAlign ? x - CGFloat(width) : x, y: y)
                CTLineDraw(line, ctx)
            }
            let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1), yellow = CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)
            let dim = CGColor(red: 0.55, green: 0.7, blue: 1, alpha: 1)
            let rows: [(String, Int, Bool, CGFloat)] = [("YOU", 0, server > 0, 150), ("AI", 1, server < 0, 24)]
            for (name, i, serving, y) in rows {
                if serving { ctx.setFillColor(yellow); ctx.fillEllipse(in: CGRect(x: 36, y: y + 28, width: 34, height: 34)) }
                text(name, x: 100, y: y, size: 92, color: white)
                text("\(games[i])", x: 640, y: y, size: 92, color: dim, rightAlign: true)
                text(points[i], x: 960, y: y, size: 92, color: yellow, rightAlign: true)
            }
            if tiebreak { text("TIEBREAK", x: 420, y: 118, size: 22, color: dim) }
        }
        px.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
    }
}
