import CoreGraphics
import Foundation

/// 8-bit RGBA colour.
struct Color: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
        a = 255
    }

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let clear = Color(r: 0, g: 0, b: 0, a: 0)

    /// Linear blend towards `other` (t = 0 → self, t = 1 → other).
    func mix(_ other: Color, _ t: Double) -> Color {
        let t = max(0, min(1, t))
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded())
        }
        return Color(r: m(r, other.r), g: m(g, other.g), b: m(b, other.b), a: m(a, other.a))
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// Top-left-origin RGBA bitmap used to paint the built-in skin's sprite sheets.
final class PixelCanvas {
    let width: Int
    let height: Int
    private var data: [UInt8]

    init(_ width: Int, _ height: Int, fill: Color = .clear) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
        if fill != .clear { self.fill(0, 0, width, height, fill) }
    }

    func set(_ x: Int, _ y: Int, _ c: Color) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        data[i] = c.r; data[i + 1] = c.g; data[i + 2] = c.b; data[i + 3] = c.a
    }

    func get(_ x: Int, _ y: Int) -> Color {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        let i = (y * width + x) * 4
        return Color(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Color) {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) { for xx in x..<(x + w) { set(xx, yy, c) } }
    }

    func hline(_ x: Int, _ y: Int, _ w: Int, _ c: Color) { fill(x, y, w, 1, c) }
    func vline(_ x: Int, _ y: Int, _ h: Int, _ c: Color) { fill(x, y, 1, h, c) }

    /// 1 px outline.
    func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Color) {
        hline(x, y, w, c); hline(x, y + h - 1, w, c)
        vline(x, y, h, c); vline(x + w - 1, y, h, c)
    }

    /// Filled face with a 1 px raised (or sunken) bevel.
    func bevel(_ x: Int, _ y: Int, _ w: Int, _ h: Int,
               face: Color, light: Color, dark: Color, sunken: Bool = false) {
        fill(x, y, w, h, face)
        let tl = sunken ? dark : light
        let br = sunken ? light : dark
        hline(x, y, w, tl); vline(x, y, h, tl)
        hline(x, y + h - 1, w, br); vline(x + w - 1, y, h, br)
    }

    /// Vertical gradient fill.
    func gradient(_ x: Int, _ y: Int, _ w: Int, _ h: Int, top: Color, bottom: Color) {
        for row in 0..<h {
            let t = h > 1 ? Double(row) / Double(h - 1) : 0
            hline(x, y + row, w, top.mix(bottom, t))
        }
    }

    /// Paints a bitmap described as rows of "X" (on) and "." (off).
    func pattern(_ rows: [String], _ x: Int, _ y: Int, _ c: Color) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch == "X" { set(x + dx, y + dy, c) }
        }
    }

    /// Draws text with the built-in pixel font. Returns the x just past the last glyph.
    @discardableResult
    func text(_ s: String, _ x: Int, _ y: Int, _ c: Color, spacing: Int = 1) -> Int {
        var cx = x
        for ch in s.uppercased() {
            let g = PixelFont.glyph(ch)
            pattern(g, cx, y, c)
            cx += PixelFont.width(of: g) + spacing
        }
        return cx - spacing
    }

    static func textWidth(_ s: String, spacing: Int = 1) -> Int {
        let widths = s.uppercased().map { PixelFont.width(of: PixelFont.glyph($0)) }
        return widths.reduce(0, +) + max(0, widths.count - 1) * spacing
    }

    func cgImage() -> CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                     | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
