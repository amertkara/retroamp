import CoreGraphics

extension DefaultSkin {
    // MARK: CBUTTONS.BMP (136×36)

    static let transportGlyphs: [[String]] = [
        ["X....X", "X...XX", "X..XXX", "X.XXXX", "X..XXX", "X...XX", "X....X"],              // previous
        ["X......", "XXX....", "XXXXX..", "XXXXXXX", "XXXXX..", "XXX....", "X......"],         // play
        ["XX..XX", "XX..XX", "XX..XX", "XX..XX", "XX..XX", "XX..XX", "XX..XX"],               // pause
        ["XXXXXXX", "XXXXXXX", "XXXXXXX", "XXXXXXX", "XXXXXXX", "XXXXXXX", "XXXXXXX"],         // stop
        ["X....X", "XX...X", "XXX..X", "XXXX.X", "XXX..X", "XX...X", "X....X"],               // next
        ["...X...", "..XXX..", ".XXXXX.", "XXXXXXX", ".......", "XXXXXXX"],                   // eject
    ]

    static func cbuttons() -> PixelCanvas {
        let c = PixelCanvas(136, 36)
        let defs: [(x: Int, w: Int, h: Int)] = [(0, 23, 18), (23, 23, 18), (46, 23, 18), (69, 23, 18), (92, 22, 18), (114, 22, 16)]
        for (i, d) in defs.enumerated() {
            transportButton(c, d.x, 0, d.w, d.h, transportGlyphs[i], pressed: false)
            transportButton(c, d.x, d.h, d.w, d.h, transportGlyphs[i], pressed: true)
        }
        return c
    }

    static func transportButton(_ c: PixelCanvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                                _ glyph: [String], pressed: Bool) {
        c.frame(x, y, w, h, Pal.shadow)
        if pressed {
            c.gradient(x + 1, y + 1, w - 2, h - 2, top: Color(0x262B35), bottom: Color(0x2E3440))
            c.hline(x + 1, y + 1, w - 2, Pal.shadow); c.vline(x + 1, y + 1, h - 2, Pal.shadow)
        } else {
            c.gradient(x + 1, y + 1, w - 2, h - 2, top: Color(0x4C5568), bottom: Color(0x343B49))
            c.hline(x + 1, y + 1, w - 2, Color(0x6A7590)); c.vline(x + 1, y + 1, h - 2, Color(0x5A6478))
            c.hline(x + 1, y + h - 2, w - 2, Pal.chassisDark); c.vline(x + w - 2, y + 1, h - 2, Pal.chassisDark)
        }
        let gw = PixelFont.width(of: glyph), gh = glyph.count
        let o = pressed ? 1 : 0
        c.pattern(glyph, x + (w - gw) / 2 + o, y + (h - gh) / 2 + o, pressed ? Pal.mint : Pal.glyph)
    }

    // MARK: SHUFREP.BMP (92×85)

    static func shufrep() -> PixelCanvas {
        let c = PixelCanvas(92, 85)
        for (x, w, label) in [(0, 28, "REP"), (28, 47, "SHUFFLE")] {
            ledButton(c, x, 0, w, 15, label, lit: false, pressed: false)
            ledButton(c, x, 15, w, 15, label, lit: false, pressed: true)
            ledButton(c, x, 30, w, 15, label, lit: true, pressed: false)
            ledButton(c, x, 45, w, 15, label, lit: true, pressed: true)
        }
        for (x, label) in [(0, "EQ"), (23, "PL")] {
            ledButton(c, x, 61, 23, 12, label, lit: false, pressed: false)
            ledButton(c, x, 73, 23, 12, label, lit: true, pressed: false)
            ledButton(c, x + 46, 61, 23, 12, label, lit: false, pressed: true)
            ledButton(c, x + 46, 73, 23, 12, label, lit: true, pressed: true)
        }
        return c
    }

    static func ledButton(_ c: PixelCanvas, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                          _ label: String, lit: Bool, pressed: Bool) {
        c.frame(x, y, w, h, Pal.shadow)
        c.bevel(x + 1, y + 1, w - 2, h - 2, face: pressed ? Pal.chassisDark : Pal.face,
                light: pressed ? Pal.shadow : Pal.faceLight, dark: pressed ? Pal.face : Pal.chassisDark)
        let o = pressed ? 1 : 0
        let ly = y + (h - 3) / 2 + o
        c.fill(x + 3 + o, ly, 3, 3, lit ? Pal.mint : Pal.ledOff)
        if lit { c.set(x + 3 + o, ly, Color(0xB8FFD6)) }
        c.text(label, x + 8 + o, y + (h - 5) / 2 + o, lit ? Pal.glyph : Pal.glyphDim)
    }

    // MARK: POSBAR.BMP (307×10)

    static func posbar() -> PixelCanvas {
        let c = PixelCanvas(307, 10, fill: Pal.chassis)
        c.bevel(0, 2, 248, 6, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
        for x in stride(from: 31, to: 248, by: 31) { c.set(x, 4, Pal.chassisDark); c.set(x, 5, Pal.chassisDark) }
        posThumb(c, 248, pressed: false)
        posThumb(c, 278, pressed: true)
        return c
    }

    static func posThumb(_ c: PixelCanvas, _ x: Int, pressed: Bool) {
        c.frame(x, 0, 29, 10, Pal.shadow)
        c.bevel(x + 1, 1, 27, 8, face: pressed ? Color(0x6F7C93) : Pal.faceLight,
                light: Color(0x8A96AE), dark: Pal.face)
        for gx in [x + 11, x + 14, x + 17] { c.vline(gx, 3, 4, pressed ? Pal.mint : Pal.chassisDark) }
    }

    // MARK: VOLUME.BMP (68×433) and BALANCE.BMP (47×433)

    static func ramp(_ t: Double) -> Color {
        gradient([(0, Pal.mint), (0.55, Pal.amber), (1, Pal.red)], t)
    }

    static func volume() -> PixelCanvas {
        let c = PixelCanvas(68, 433, fill: Pal.chassis)
        for i in 0..<28 {
            let y = i * 15, t = Double(i) / 27
            c.bevel(0, y + 2, 68, 9, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
            let filled = Int((t * 66).rounded())
            for x in 0..<66 {
                let h = 1 + x * 6 / 65  // rising wedge, 1…7 px
                c.vline(1 + x, y + 10 - h, h, x < filled ? ramp(Double(x) / 65) : Pal.ghost)
            }
        }
        knob(c, 15, 422, pressed: false)
        knob(c, 0, 422, pressed: true)
        return c
    }

    static func balance() -> PixelCanvas {
        let c = PixelCanvas(47, 433, fill: Pal.chassis)
        for i in 0..<28 {
            let y = i * 15, t = Double(i) / 27
            c.bevel(9, y + 2, 38, 9, face: Pal.lcd, light: Pal.chassisLight, dark: Pal.shadow, sunken: true)
            let reach = Int((t * 17).rounded())
            for d in 0..<18 {
                let col = d <= reach && reach > 0 ? ramp(Double(d) / 17) : Pal.ghost
                c.vline(9 + 18 - d, y + 4, 5, col)
                c.vline(9 + 19 + d, y + 4, 5, col)
            }
            c.vline(9 + 18, y + 3, 7, Pal.dim); c.vline(9 + 19, y + 3, 7, Pal.dim)
        }
        knob(c, 15, 422, pressed: false)
        knob(c, 0, 422, pressed: true)
        return c
    }

    static func knob(_ c: PixelCanvas, _ x: Int, _ y: Int, pressed: Bool) {
        c.frame(x, y, 14, 11, Pal.shadow)
        c.bevel(x + 1, y + 1, 12, 9, face: pressed ? Color(0x6F7C93) : Pal.faceLight,
                light: Color(0x8A96AE), dark: Pal.face)
        for gx in [x + 4, x + 6, x + 8] { c.vline(gx, y + 3, 5, pressed ? Pal.mint : Pal.chassisDark) }
    }

    // MARK: MONOSTER.BMP (56×24) and PLAYPAUS.BMP (42×9)

    static func monoster() -> PixelCanvas {
        let c = PixelCanvas(56, 24, fill: Pal.lcd)
        let off = Color(0x173A28)
        for (x, w, label) in [(0, 29, "STEREO"), (29, 27, "MONO")] {
            let tx = x + (w - PixelCanvas.textWidth(label)) / 2
            c.text(label, tx, 3, Pal.mint)
            c.text(label, tx, 15, off)
        }
        return c
    }

    static func playpaus() -> PixelCanvas {
        let c = PixelCanvas(42, 9, fill: Pal.lcd)
        c.pattern(["X...", "XX..", "XXX.", "XXXX", "XXX.", "XX..", "X..."], 3, 1, Pal.mint)
        c.pattern(["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"], 11, 1, Pal.amber)
        c.fill(20, 2, 5, 5, Pal.red)
        c.fill(36, 2, 2, 5, Pal.ghost)   // "not working" LED
        c.fill(39, 2, 2, 5, Pal.mint)    // "working" LED
        return c
    }

    // MARK: NUMBERS.BMP (99×13)

    /// Seven-segment patterns for 0–9 in the order A B C D E F G.
    static let segments: [[Bool]] = [
        [true, true, true, true, true, true, false], [false, true, true, false, false, false, false],
        [true, true, false, true, true, false, true], [true, true, true, true, false, false, true],
        [false, true, true, false, false, true, true], [true, false, true, true, false, true, true],
        [true, false, true, true, true, true, true], [true, true, true, false, false, false, false],
        [true, true, true, true, true, true, true], [true, true, true, true, false, true, true],
    ]

    /// Draws one 9×13 seven-segment digit (nil = all segments unlit).
    static func digit(_ c: PixelCanvas, _ d: Int?, _ x: Int, _ y: Int, on: Color, off: Color) {
        let lit = d.map { segments[$0] } ?? [Bool](repeating: false, count: 7)
        func col(_ s: Int) -> Color { lit[s] ? on : off }
        // A, D, G: horizontal trapezoids.
        c.hline(x + 2, y, 5, col(0)); c.hline(x + 3, y + 1, 3, col(0))
        c.hline(x + 2, y + 12, 5, col(3)); c.hline(x + 3, y + 11, 3, col(3))
        c.hline(x + 2, y + 6, 5, col(6)); c.hline(x + 3, y + 5, 3, col(6)); c.hline(x + 3, y + 7, 3, col(6))
        // F, B (upper) and E, C (lower): vertical trapezoids.
        c.vline(x + 1, y + 1, 5, col(5)); c.vline(x + 2, y + 2, 3, col(5))
        c.vline(x + 7, y + 1, 5, col(1)); c.vline(x + 6, y + 2, 3, col(1))
        c.vline(x + 1, y + 7, 5, col(4)); c.vline(x + 2, y + 8, 3, col(4))
        c.vline(x + 7, y + 7, 5, col(2)); c.vline(x + 6, y + 8, 3, col(2))
    }

    static func numbers() -> PixelCanvas {
        let c = PixelCanvas(99, 13, fill: Pal.lcd)
        for d in 0...9 { digit(c, d, d * 9, 0, on: Pal.mint, off: Pal.ghost) }
        digit(c, nil, 90, 0, on: Pal.mint, off: Pal.ghost)
        return c
    }

    // MARK: TEXT.BMP (155×18)

    static func text() -> PixelCanvas {
        let c = PixelCanvas(155, 18, fill: Pal.lcd)
        for (r, row) in PixelFont.textRows.enumerated() {
            for (col, ch) in row.enumerated() {
                guard let ch else { continue }
                c.pattern(PixelFont.glyph(ch), col * 5, r * 6, Pal.mint)
            }
        }
        return c
    }
}
