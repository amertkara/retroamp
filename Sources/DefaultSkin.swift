import CoreGraphics

/// Colours of the built-in "Retroamp" skin (original artwork, drawn in code).
enum Pal {
    static let lcd = Color(0x0A0F14)
    static let mint = Color(0x39FF88)
    static let ghost = Color(0x0F2A1C)
    static let dim = Color(0x1E6B45)
    static let chassis = Color(0x2E3440)
    static let chassisLight = Color(0x434C5E)
    static let chassisDark = Color(0x1B1F27)
    static let shadow = Color(0x101318)
    static let amber = Color(0xF2A93B)
    static let amberDark = Color(0x9C6A22)
    static let face = Color(0x3B4252)
    static let faceLight = Color(0x5A6478)
    static let glyph = Color(0xD8DEE9)
    static let glyphDim = Color(0x7B8394)
    static let red = Color(0xFF4B4B)
    static let orange = Color(0xFF5A3C)
    static let peak = Color(0xE0E6F0)
    static let ledOff = Color(0x14301F)
}

/// Paints the built-in skin into sprite sheets with the classic skin layout, so the
/// renderer treats it exactly like a loaded .wsz skin.
enum DefaultSkin {
    static func makeSheets() -> [SheetName: CGImage] {
        [
            .main: main().cgImage(), .titlebar: titlebar().cgImage(),
            .cbuttons: cbuttons().cgImage(), .shufrep: shufrep().cgImage(),
            .posbar: posbar().cgImage(), .volume: volume().cgImage(),
            .balance: balance().cgImage(), .monoster: monoster().cgImage(),
            .playpaus: playpaus().cgImage(), .numbers: numbers().cgImage(),
            .text: text().cgImage(), .pledit: pledit().cgImage(),
        ]
    }

    /// VISCOLOR.TXT equivalent: 0 background, 1 dots, 2–17 spectrum (top → bottom),
    /// 18–22 oscilloscope, 23 peaks.
    static let visColors: [Color] = {
        var c: [Color] = [Pal.lcd, Color(0x16202A)]
        let stops: [(Double, Color)] = [(0, Pal.red), (0.3, Pal.amber), (0.65, Pal.mint), (1, Color(0x1FA862))]
        for i in 0..<16 { c.append(gradient(stops, Double(i) / 15)) }
        c += [Color(0xD2FFE6), Color(0x9CFFC4), Pal.mint, Color(0x2BD872), Color(0x1FA862)]
        c.append(Pal.peak)
        return c
    }()

    static func gradient(_ stops: [(Double, Color)], _ t: Double) -> Color {
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1]
            let (t1, c1) = stops[i]
            return c0.mix(c1, (t - t0) / (t1 - t0))
        }
        return stops[stops.count - 1].1
    }

    /// Recessed LCD panel.
    static func lcdBox(_ c: PixelCanvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.bevel(x, y, w, h, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
    }

    // MARK: MAIN.BMP (275×116)

    static func main() -> PixelCanvas {
        let c = PixelCanvas(275, 116, fill: Pal.chassis)
        c.gradient(1, 84, 273, 31, top: Pal.chassis, bottom: Color(0x262B35))
        c.hline(0, 0, 275, Pal.chassisLight); c.vline(0, 0, 116, Pal.chassisLight)
        c.hline(0, 115, 275, Pal.shadow); c.vline(274, 0, 116, Pal.shadow)
        c.hline(8, 70, 259, Pal.chassisDark); c.hline(8, 71, 259, Color(0x3A4150))

        lcdBox(c, 20, 22, 84, 41)    // time, play state, visualizer
        lcdBox(c, 108, 22, 161, 16)  // marquee
        lcdBox(c, 108, 40, 161, 14)  // kbps / kHz / mono / stereo
        c.text("KBPS", 128, 43, Pal.dim)
        c.text("KHZ", 168, 43, Pal.dim)
        for x in [48, 60, 78, 90] { digit(c, nil, x, 26, on: Pal.mint, off: Pal.ghost) }
        c.fill(72, 29, 2, 2, Pal.mint); c.fill(72, 34, 2, 2, Pal.mint)

        c.bevel(14, 86, 146, 22, face: Color(0x22262F), light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
        logo(c, 253, 91)
        return c
    }

    /// Small analyzer-style badge in the bottom-right "about" area (13×15).
    static func logo(_ c: PixelCanvas, _ x: Int, _ y: Int) {
        c.bevel(x, y, 13, 15, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
        for (i, h) in [5, 10, 7, 3].enumerated() {
            let bx = x + 1 + i * 3
            for r in 0..<h {
                let row = 12 - r  // 0 = top of the 13-row interior
                c.hline(bx, y + 1 + row, 2, visColors[2 + row * 15 / 12])
            }
            c.hline(bx, y + 1 + 12 - h - 1, 2, Pal.peak)
        }
    }

    // MARK: TITLEBAR.BMP (344×87)

    enum TitleGlyph { case options, minimize, shade, unshade, close }

    static let clutterSlots: [(y: Int, h: Int, ch: Character)] = [
        (3, 8, "O"), (11, 7, "A"), (18, 7, "I"), (25, 8, "D"), (33, 7, "V"),
    ]

    static func titlebar() -> PixelCanvas {
        let c = PixelCanvas(344, 87)
        titleBar(c, 27, 0, active: true)
        titleBar(c, 27, 15, active: false)
        titleBar(c, 27, 29, active: true)   // windowshade bars (not used yet)
        titleBar(c, 27, 42, active: false)
        let buttons: [(TitleGlyph, Int, Int)] = [
            (.options, 0, 0), (.minimize, 9, 0), (.close, 18, 0), (.shade, 0, 18), (.unshade, 0, 27),
        ]
        for (g, x, y) in buttons {
            titleButton(c, x, y, g, pressed: false)
            if y >= 18 { titleButton(c, x + 9, y, g, pressed: true) } else { titleButton(c, x, y + 9, g, pressed: true) }
        }
        c.bevel(0, 36, 17, 7, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
        c.fill(20, 36, 3, 7, Pal.faceLight)

        clutter(c, 304, 0, lit: nil, disabled: false)
        clutter(c, 312, 0, lit: nil, disabled: true)
        for k in 0..<5 { clutter(c, 304 + 8 * k, 44, lit: k, disabled: false) }
        return c
    }

    static func titleBar(_ c: PixelCanvas, _ x: Int, _ y: Int, active: Bool) {
        let edge = active ? Color(0x56607A) : Pal.chassisLight
        c.gradient(x, y, 275, 14, top: active ? Color(0x3A4252) : Color(0x30353F),
                   bottom: active ? Color(0x232833) : Color(0x262A32))
        c.hline(x, y, 275, edge); c.vline(x, y, 14, edge)
        c.hline(x, y + 13, 275, Pal.shadow); c.vline(x + 274, y, 14, Pal.shadow)

        let title = "RETROAMP"
        let tw = PixelCanvas.textWidth(title, spacing: 2)
        let tx = x + (275 - tw) / 2
        c.text(title, tx, y + 5, active ? Pal.glyph : Pal.glyphDim, spacing: 2)

        let a = active ? Pal.amber : Color(0x4A5263)
        let b = active ? Pal.amberDark : Color(0x3A4150)
        for (i, sy) in [4, 6, 8, 10].enumerated() {
            let col = i % 2 == 0 ? a : b
            c.hline(x + 19, y + sy, tx - 5 - (x + 19), col)
            c.hline(tx + tw + 5, y + sy, (x + 241) - (tx + tw + 5), col)
        }
    }

    static func titleButton(_ c: PixelCanvas, _ x: Int, _ y: Int, _ g: TitleGlyph, pressed: Bool) {
        c.bevel(x, y, 9, 9, face: pressed ? Pal.chassisDark : Pal.face,
                light: Pal.faceLight, dark: Pal.shadow, sunken: pressed)
        let rows: [String]
        switch g {
        case .options: rows = ["XXXXX", ".....", "XXXXX", ".....", "XXXXX"]
        case .minimize: rows = [".....", ".....", ".....", ".....", "XXXXX"]
        case .shade: rows = ["XXXXX", "XXXXX", ".....", ".....", "....."]
        case .unshade: rows = [".....", ".....", ".....", "XXXXX", "XXXXX"]
        case .close: rows = ["X...X", ".X.X.", "..X..", ".X.X.", "X...X"]
        }
        let o = pressed ? 1 : 0
        c.pattern(rows, x + 2 + o, y + 2 + o, pressed ? Pal.mint : Pal.glyph)
    }

    /// The O/A/I/D/V "clutter bar" (8×43), optionally with one button lit.
    static func clutter(_ c: PixelCanvas, _ x: Int, _ y: Int, lit: Int?, disabled: Bool) {
        c.fill(x, y, 8, 43, Pal.chassisDark)
        c.vline(x, y, 43, Pal.shadow); c.vline(x + 7, y, 43, Pal.chassisLight)
        c.hline(x, y, 8, Pal.shadow); c.hline(x, y + 42, 8, Pal.chassisLight)
        for (i, s) in clutterSlots.enumerated() {
            let on = lit == i
            if on { c.fill(x + 1, y + s.y, 6, s.h, Pal.ledOff) }
            let g = PixelFont.glyph(s.ch)
            let col = on ? Pal.mint : (disabled ? Pal.chassisLight : Pal.faceLight)
            c.pattern(g, x + (8 - PixelFont.width(of: g)) / 2, y + s.y + (s.h - 5) / 2, col)
        }
    }
}
