import Metal
import CoreGraphics
import CoreText
import Foundation

/// Sponsor strip for the LED ribbon boards. Drawn once with CoreText; the shader scrolls it along the boards.
final class AdTexture {
    static let width = 2048, height = 128
    let texture: MTLTexture

    init?(device: MTLDevice) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        draw()
    }

    private func draw() {
        let w = Self.width, h = Self.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(red: 0.02, green: 0.05, blue: 0.20, alpha: 1),
                                                                                              CGColor(red: 0.03, green: 0.10, blue: 0.35, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
            let brands: [(String, CGColor)] = [
                ("TENNISSIM", CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)), ("APPLE SILICON", CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
                ("METAL 4", CGColor(red: 0.35, green: 0.9, blue: 1, alpha: 1)), ("METALFX", CGColor(red: 1, green: 0.45, blue: 0.85, alpha: 1)),
                ("SWIFT", CGColor(red: 1, green: 0.55, blue: 0.2, alpha: 1)), ("BLENDER", CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1))]
            let font = CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, 84, nil)
            var x: CGFloat = 30
            let cell = CGFloat(w) / CGFloat(brands.count)
            for (i, b) in brands.enumerated() {
                func make(_ f: CTFont) -> (CTLine, CGFloat) {
                    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                                NSAttributedString.Key(kCTForegroundColorAttributeName as String): b.1]
                    let l = CTLineCreateWithAttributedString(NSAttributedString(string: b.0, attributes: attrs))
                    return (l, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)))
                }
                var (line, tw) = make(font)
                let maxW = cell - 90                                          // fallback fonts are wider: shrink to fit the cell
                if tw > maxW { (line, tw) = make(CTFontCreateCopyWithAttributes(font, 84 * maxW / tw, nil, nil)) }
                ctx.textPosition = CGPoint(x: x + (cell - tw) / 2 - 30, y: 30)
                CTLineDraw(line, ctx)
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
                ctx.fill(CGRect(x: x + cell - 34, y: 58, width: 14, height: 14))      // separator diamond-ish block
                x += cell
                _ = i
            }
        }
        px.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
    }
}
