import CoreGraphics
import CoreText
import Foundation

/// Everything the playlist editor needs to draw one frame.
struct PlaylistRenderState {
    var geometry = PlaylistGeometry(cols: 0, rows: 4)
    var active = true
    var entries: [PlaylistEntry] = []
    var numbered = true
    var selection = Set<Int>()
    var current: Int?
    var offset = 0                  // first visible entry
    var pressed: PlaylistHit?       // close/shade button held down
    var handlePressed = false
    var openMenu: PlaylistMenu?
    var menuHover: Int?
    var runningTime = ""
    var miniTime = "     "          // sign, m, m, s, s
}

/// Draws the playlist editor. The frame is composed at 1× from PLEDIT.BMP and scaled up with
/// nearest-neighbour filtering; track names are drawn on top at full resolution in the skin's
/// PLEDIT.TXT font, as the classic playlist used a real system font.
final class PlaylistRenderer {
    private var ctx: CGContext?
    private var height = 0

    /// Draws into `target`, whose user space has `scale` units per skin pixel and a bottom-left origin.
    func draw(skin: Skin, state s: PlaylistRenderState, in target: CGContext, scale: CGFloat) {
        guard let chrome = renderChrome(skin, s) else { return }
        let g = s.geometry
        target.saveGState()
        target.interpolationQuality = .none
        target.draw(chrome, in: CGRect(x: 0, y: 0, width: CGFloat(g.width) * scale, height: CGFloat(g.height) * scale))
        drawRows(skin, s, target, scale)
        if let m = s.openMenu { drawMenu(skin, m, s, target, scale) }
        target.restoreGState()
    }

    /// Renders a standalone image (used by the snapshot tool).
    func image(skin: Skin, state: PlaylistRenderState, scale: Int) -> CGImage? {
        let g = state.geometry
        guard let c = CGContext(data: nil, width: g.width * scale, height: g.height * scale, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(skin: skin, state: state, in: c, scale: CGFloat(scale))
        return c.makeImage()
    }

    // MARK: Frame (1×)

    private func context(_ g: PlaylistGeometry) -> CGContext? {
        if let c = ctx, c.width == g.width, c.height == g.height { return c }
        ctx = CGContext(data: nil, width: g.width, height: g.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .none
        ctx?.setShouldAntialias(false)
        return ctx
    }

    private func renderChrome(_ skin: Skin, _ s: PlaylistRenderState) -> CGImage? {
        let g = s.geometry
        guard let c = context(g) else { return nil }
        height = g.height
        let W = g.width, H = g.height
        c.clear(CGRect(x: 0, y: 0, width: W, height: H))

        // Track list background and selection.
        let style = skin.playlistStyle
        fill(c, style.normalBG, g.list)
        for i in 0..<g.visibleRows where s.selection.contains(s.offset + i) && s.offset + i < s.entries.count {
            fill(c, style.selectedBG, g.rowRect(i))
        }

        // Top: corner, (spacer), fill, title, (spacer), fill, corner.
        let a = s.active
        draw(c, skin, PlaylistSprites.topLeft(a), 0, 0)
        var x = 25
        if g.showSpacers { tile(c, skin, PlaylistSprites.topTile(a), x, 0, 12, 20); x += 12 }
        tile(c, skin, PlaylistSprites.topTile(a), x, 0, g.fillWidth, 20)
        x += g.fillWidth
        draw(c, skin, PlaylistSprites.title(a), x, 0)
        x += 100
        if g.showSpacers { tile(c, skin, PlaylistSprites.topTile(a), x, 0, 13, 20); x += 13 }
        tile(c, skin, PlaylistSprites.topTile(a), x, 0, W - 25 - x, 20)
        draw(c, skin, PlaylistSprites.topRight(a), W - 25, 0)
        if s.pressed == .close { draw(c, skin, PlaylistSprites.closePressed, W - 11, 3) }
        if s.pressed == .shade { draw(c, skin, PlaylistSprites.shadePressed, W - 21, 3) }

        // Sides, and the scrollbar handle in the right-hand tile.
        tile(c, skin, PlaylistSprites.leftTile, 0, 20, 12, H - 58)
        tile(c, skin, PlaylistSprites.rightTile, W - 20, 20, 20, H - 58)
        let overflow = max(0, s.entries.count - g.visibleRows)
        let frac = overflow > 0 ? Double(min(s.offset, overflow)) / Double(overflow) : 0
        draw(c, skin, PlaylistSprites.handle(s.handlePressed), W - 15, 20 + Int((frac * Double(g.handleTravel)).rounded()))

        // Bottom: tiles, then the visualizer art, then the two corners.
        tile(c, skin, PlaylistSprites.bottomTile, 0, H - 38, W, 38)
        if g.showVisualizerArt { draw(c, skin, PlaylistSprites.visualizer, W - 225, H - 38) }
        draw(c, skin, PlaylistSprites.bottomLeft, 0, H - 38)
        draw(c, skin, PlaylistSprites.bottomRight, W - 150, H - 38)

        // Running time ("selected/total") and the mini time, in TEXT.BMP characters.
        let rt = g.runningTime
        let running = s.runningTime.padding(toLength: 18, withPad: " ", startingAt: 0)
        for (i, cell) in PixelFont.cells(for: running).prefix(18).enumerated() {
            draw(c, skin, Sprites.textCell(cell.col, cell.row), rt.x + i * 5, rt.y)
        }
        let space = PixelFont.cells(for: " ")[0]
        let mini = Array(s.miniTime.padding(toLength: 5, withPad: " ", startingAt: 0))
        for (i, mx) in g.miniTimeX.enumerated() {
            draw(c, skin, Sprites.textCell(space.col, space.row), mx, g.miniTimeY)
            if let cell = PixelFont.cells(for: String(mini[i])).first, mini[i] != " " {
                draw(c, skin, Sprites.textCell(cell.col, cell.row), mx, g.miniTimeY)
            }
        }
        return c.makeImage()
    }

    private func draw(_ c: CGContext, _ skin: Skin, _ sprite: Sprite, _ x: Int, _ y: Int) {
        guard let img = skin.image(sprite) else { return }
        c.draw(img, in: CGRect(x: x, y: height - y - img.height, width: img.width, height: img.height))
    }

    /// Repeats a sprite across a rectangle, starting at its top-left corner.
    private func tile(_ c: CGContext, _ skin: Skin, _ sprite: Sprite, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        c.saveGState()
        c.clip(to: CGRect(x: x, y: height - y - h, width: w, height: h))
        for ty in stride(from: y, to: y + h, by: sprite.h) {
            for tx in stride(from: x, to: x + w, by: sprite.w) { draw(c, skin, sprite, tx, ty) }
        }
        c.restoreGState()
    }

    private func fill(_ c: CGContext, _ color: Color, _ r: CGRect) {
        c.setFillColor(color.cgColor)
        c.fill(CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
    }

    // MARK: Track rows (full resolution)

    private var fontCache: (name: String, size: CGFloat, font: CTFont)?

    private func font(_ name: String, size: CGFloat) -> CTFont {
        if let f = fontCache, f.name == name, f.size == size { return f.font }
        var font = CTFontCreateWithName("Arial" as CFString, size, nil)
        let requested = CTFontCreateWithName(name as CFString, size, nil)
        let family = CTFontCopyFamilyName(requested) as String
        if family.caseInsensitiveCompare(name) == .orderedSame { font = requested }
        fontCache = (name, size, font)
        return font
    }

    private func line(_ text: String, _ font: CTFont, _ color: CGColor, kern: CGFloat) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private func drawRows(_ skin: Skin, _ s: PlaylistRenderState, _ c: CGContext, _ scale: CGFloat) {
        let g = s.geometry
        let style = skin.playlistStyle
        let f = font(style.font, size: 9 * scale)
        let kern = 0.5 * scale
        let H = CGFloat(g.height) * scale
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f)
        let rowH = CGFloat(PlaylistGeometry.rowHeight) * scale
        let baselineInRow = (rowH - ascent - descent) / 2 + ascent

        let start = min(s.offset, s.entries.count)
        let visible = Array(s.entries[start...].prefix(g.visibleRows))
        guard !visible.isEmpty else { return }
        let digits = String(s.entries.count).count

        struct Row { let title: CTLine; let duration: CTLine; let durationWidth: CGFloat }
        var rows: [Row] = []
        for (i, e) in visible.enumerated() {
            let index = start + i
            let color = (index == s.current ? style.current : style.normal).cgColor
            var title = e.title
            if s.numbered {
                let n = String(index + 1)
                title = String(repeating: "\u{00A0}", count: max(0, digits - n.count)) + n + ". " + title
            }
            let d = line(e.durationText, f, color, kern: kern)
            rows.append(Row(title: line(title, f, color, kern: kern), duration: d,
                            durationWidth: CGFloat(CTLineGetTypographicBounds(d, nil, nil, nil))))
        }

        let maxDuration = rows.map(\.durationWidth).max() ?? 0
        let listLeft = 12 * scale
        let listRight = CGFloat(g.width - 20) * scale
        let durationColumn = maxDuration > 0 ? maxDuration + 3 * scale : 0
        let titleWidth = listRight - listLeft - durationColumn
        let ellipsis = line("\u{2026}", f, style.normal.cgColor, kern: kern)

        c.saveGState()
        c.clip(to: CGRect(x: listLeft, y: H - CGFloat(g.height - 38) * scale,
                          width: listRight - listLeft, height: CGFloat(g.height - 58) * scale))
        c.setShouldAntialias(true)
        c.setShouldSmoothFonts(false)
        c.textMatrix = .identity
        for (i, row) in rows.enumerated() {
            let top = CGFloat(23 + PlaylistGeometry.rowHeight * i) * scale
            let baseline = (H - top - baselineInRow).rounded()
            if titleWidth > 4 * scale,
               let t = CTLineCreateTruncatedLine(row.title, Double(titleWidth), .end, ellipsis) {
                c.textPosition = CGPoint(x: listLeft, y: baseline)
                CTLineDraw(t, c)
            }
            if row.durationWidth > 0 {
                c.textPosition = CGPoint(x: listRight - 3 * scale - row.durationWidth, y: baseline)
                CTLineDraw(row.duration, c)
            }
        }
        c.restoreGState()
    }

    // MARK: Pop-up menus (drawn over the rows)

    private func drawMenu(_ skin: Skin, _ m: PlaylistMenu, _ s: PlaylistRenderState, _ c: CGContext, _ scale: CGFloat) {
        let g = s.geometry
        let H = CGFloat(g.height)
        func put(_ sprite: Sprite, _ r: CGRect) {
            guard let img = skin.image(sprite) else { return }
            c.draw(img, in: CGRect(x: r.minX * scale, y: (H - r.maxY) * scale, width: r.width * scale, height: r.height * scale))
        }
        put(m.bar, g.menuBar(m))
        for (i, item) in m.items.enumerated() {
            put(item.sprite(hover: s.menuHover == i), g.menuItem(m, i))
        }
    }
}
