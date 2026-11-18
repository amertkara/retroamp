import CoreGraphics

extension DefaultSkin {
    /// PLEDIT.TXT equivalent for the built-in skin.
    static let playlistStyle = PlaylistStyle(normal: Pal.mint, current: Pal.amber, normalBG: Pal.lcd,
                                             selectedBG: Color(0x23395B), font: "Arial")

    // MARK: PLEDIT.BMP (280×186)

    enum TopPiece { case leftCorner, title, tile, rightCorner }

    static func pledit() -> PixelCanvas {
        let c = PixelCanvas(280, 186)
        for (active, y) in [(true, 0), (false, 21)] {
            playlistTop(c, 0, y, 25, .leftCorner, active: active)
            playlistTop(c, 26, y, 100, .title, active: active)
            playlistTop(c, 127, y, 25, .tile, active: active)
            playlistTop(c, 153, y, 25, .rightCorner, active: active)
        }
        playlistSides(c)
        titleButton(c, 52, 42, .close, pressed: true)
        titleButton(c, 62, 42, .shade, pressed: true)
        scrollHandle(c, 52, 53, pressed: false)
        scrollHandle(c, 61, 53, pressed: true)
        playlistBottom(c)
        playlistMenus(c)
        return c
    }

    /// Top bar pieces (20 px): a 14 px title strip over 6 px of frame. The bottom row is the
    /// sunken top edge of the track list, which spans x 11…W-20 of the window.
    static func playlistTop(_ c: PixelCanvas, _ x: Int, _ y: Int, _ w: Int, _ piece: TopPiece, active: Bool) {
        let edge = active ? Color(0x56607A) : Pal.chassisLight
        c.gradient(x, y, w, 14, top: active ? Color(0x3A4252) : Color(0x30353F),
                   bottom: active ? Color(0x232833) : Color(0x262A32))
        c.hline(x, y, w, edge)
        c.hline(x, y + 13, w, Pal.shadow)
        c.fill(x, y + 14, w, 6, Pal.chassis)

        let a = active ? Pal.amber : Color(0x4A5263)
        let b = active ? Pal.amberDark : Color(0x3A4150)
        func stripes(_ from: Int, _ to: Int) {
            guard to > from else { return }
            for (i, sy) in [4, 6, 8, 10].enumerated() { c.hline(x + from, y + sy, to - from, i % 2 == 0 ? a : b) }
        }

        switch piece {
        case .leftCorner:
            stripes(4, w)
            c.vline(x, y, 20, edge)
            c.hline(x + 11, y + 19, w - 11, Pal.shadow)
        case .title:
            let title = "PLAYLIST"
            let tw = PixelCanvas.textWidth(title, spacing: 2)
            let tx = (w - tw) / 2
            c.text(title, x + tx, y + 5, active ? Pal.glyph : Pal.glyphDim, spacing: 2)
            stripes(0, tx - 5)
            stripes(tx + tw + 5, w)
            c.hline(x, y + 19, w, Pal.shadow)
        case .tile:
            stripes(0, w)
            c.hline(x, y + 19, w, Pal.shadow)
        case .rightCorner:
            stripes(0, 2)
            titleButton(c, x + 4, y + 3, .shade, pressed: false)
            titleButton(c, x + 14, y + 3, .close, pressed: false)
            c.vline(x + w - 1, y, 20, Pal.shadow)
            c.hline(x, y + 19, 5, Pal.shadow)
            c.set(x + 5, y + 19, Pal.chassisLight)
        }
    }

    /// Left and right frame tiles (29 px tall, repeated down the window).
    static func playlistSides(_ c: PixelCanvas) {
        c.fill(0, 42, 12, 29, Pal.chassis)
        c.vline(0, 42, 29, Pal.chassisLight)
        c.vline(11, 42, 29, Pal.shadow)

        c.fill(31, 42, 20, 29, Pal.chassis)
        c.vline(31, 42, 29, Pal.chassisLight)       // sunken right edge of the list
        c.vline(50, 42, 29, Pal.shadow)             // outer edge
        c.fill(36, 42, 8, 29, Pal.chassisDark)      // scrollbar groove (x 5…12 of the tile)
        c.vline(36, 42, 29, Pal.shadow)
        c.vline(43, 42, 29, Color(0x3A4150))
    }

    static func scrollHandle(_ c: PixelCanvas, _ x: Int, _ y: Int, pressed: Bool) {
        c.frame(x, y, 8, 18, Pal.shadow)
        c.bevel(x + 1, y + 1, 6, 16, face: pressed ? Color(0x6F7C93) : Pal.faceLight,
                light: Color(0x8A96AE), dark: Pal.face)
        for gy in [y + 6, y + 8, y + 10] { c.hline(x + 2, gy, 4, pressed ? Pal.mint : Pal.chassisDark) }
    }

    /// Bottom pieces (38 px). The top row is the sunken bottom edge of the track list.
    static func playlistBottom(_ c: PixelCanvas) {
        func base(_ x: Int, _ y: Int, _ w: Int) {
            c.fill(x, y, w, 38, Pal.chassis)
            c.hline(x, y + 37, w, Pal.shadow)
        }

        // Tile (179, 0) and visualizer background (205, 0).
        base(179, 0, 25)
        c.hline(179, 0, 25, Pal.chassisLight)
        base(205, 0, 75)
        c.hline(205, 0, 75, Pal.chassisLight)
        lcdBox(c, 206, 11, 74, 18)

        // Bottom-left corner (0, 72): ADD, REM, SEL and MISC buttons.
        base(0, 72, 125)
        c.vline(0, 72, 37, Pal.chassisLight)
        c.hline(11, 72, 114, Pal.chassisLight)
        for (x, label) in [(14, "ADD"), (43, "REM"), (72, "SEL"), (101, "MISC")] {
            playlistButton(c, x, 80, label, hover: false)
        }

        // Bottom-right corner (126, 72).
        let x0 = 126, y0 = 72
        base(x0, y0, 150)
        c.hline(x0, y0, 131, Pal.chassisLight)
        c.vline(x0 + 149, y0, 38, Pal.shadow)
        lcdBox(c, x0 + 5, y0 + 8, 94, 10)            // running time (text at 7, 10)
        playlistButton(c, x0 + 106, y0 + 8, "LIST", hover: false)

        // Mini transport: six 10×10 buttons from (3, 22).
        let glyphs: [[String]] = [
            ["X...X", "X..XX", "X.XXX", "X..XX", "X...X"],
            ["X...", "XX..", "XXX.", "XX..", "X..."],
            ["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"],
            ["XXXX", "XXXX", "XXXX", "XXXX"],
            ["X...X", "XX..X", "XXX.X", "XX..X", "X...X"],
            ["..X..", ".XXX.", "XXXXX", ".....", "XXXXX"],
        ]
        for (i, g) in glyphs.enumerated() {
            let bx = x0 + 3 + i * 10, by = y0 + 22
            c.bevel(bx, by, 10, 10, face: Pal.face, light: Pal.faceLight, dark: Pal.shadow)
            c.pattern(g, bx + (10 - PixelFont.width(of: g)) / 2, by + (10 - g.count) / 2, Pal.glyph)
        }

        // Mini time (characters at 67…95, 23…28) with its colon.
        lcdBox(c, x0 + 65, y0 + 21, 33, 10)
        c.set(x0 + 84, y0 + 24, Pal.mint)
        c.set(x0 + 84, y0 + 26, Pal.mint)

        // Scroll up/down arrows under the scrollbar (x 135…142).
        c.pattern(["...XX...", "..XXXX..", ".XXXXXX."], x0 + 135, y0 + 3, Pal.glyphDim)
        c.pattern([".XXXXXX.", "..XXXX..", "...XX..."], x0 + 135, y0 + 9, Pal.glyphDim)

        // Resize grip in the bottom-right corner.
        for d in stride(from: 3, through: 11, by: 4) {
            for t in 0...d {
                c.set(x0 + 147 - d + t, y0 + 35 - t, Pal.chassisLight)
                c.set(x0 + 148 - d + t, y0 + 35 - t, Pal.shadow)
            }
        }
    }

    static func playlistButton(_ c: PixelCanvas, _ x: Int, _ y: Int, _ label: String, hover: Bool) {
        c.frame(x, y, 22, 18, Pal.shadow)
        if hover {
            c.gradient(x + 1, y + 1, 20, 16, top: Color(0x262B35), bottom: Color(0x2E3440))
            c.hline(x + 1, y + 1, 20, Pal.shadow); c.vline(x + 1, y + 1, 16, Pal.shadow)
        } else {
            c.gradient(x + 1, y + 1, 20, 16, top: Color(0x4C5568), bottom: Color(0x343B49))
            c.hline(x + 1, y + 1, 20, Color(0x6A7590)); c.vline(x + 1, y + 1, 16, Color(0x5A6478))
            c.hline(x + 1, y + 16, 20, Pal.chassisDark); c.vline(x + 20, y + 1, 16, Pal.chassisDark)
        }
        let o = hover ? 1 : 0
        let tw = PixelCanvas.textWidth(label)
        c.text(label, x + (22 - tw) / 2 + o, y + 7 + o, hover ? Pal.mint : Pal.glyph)
    }

    /// Pop-up menu entries (normal, and highlighted 23 px to the right) and their side bars.
    static func playlistMenus(_ c: PixelCanvas) {
        let columns: [(x: Int, labels: [String], barX: Int, barH: Int)] = [
            (0, ["URL", "DIR", "FILE"], 48, 54),
            (54, ["ALL", "CROP", "SEL", "MISC"], 100, 72),
            (104, ["INV", "NONE", "ALL"], 150, 54),
            (154, ["SORT", "INFO", "OPTS"], 200, 54),
            (204, ["NEW", "SAVE", "LOAD"], 250, 54),
        ]
        for col in columns {
            for (i, label) in col.labels.enumerated() {
                let y = 111 + i * 19
                playlistButton(c, col.x, y, label, hover: false)
                playlistButton(c, col.x + 23, y, label, hover: true)
            }
            menuBar(c, col.barX, 111, col.barH)
        }
    }

    static func menuBar(_ c: PixelCanvas, _ x: Int, _ y: Int, _ h: Int) {
        c.vline(x, y, h, Pal.shadow)
        c.vline(x + 1, y, h, Pal.amber)
        c.vline(x + 2, y, h, Pal.amberDark)
    }
}
