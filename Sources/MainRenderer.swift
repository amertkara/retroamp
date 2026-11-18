import CoreGraphics
import Foundation

enum PlaybackState { case stopped, playing, paused }

enum VisMode: Int { case bars = 0, oscilloscope = 1, off = 2 }

/// Everything the main window needs to draw one frame.
struct RenderState {
    var playback: PlaybackState = .stopped
    var elapsed: Double = 0
    var duration: Double = 0
    var volume: Int = 50
    var balance: Int = 0
    var shuffle = false
    var repeating = false
    var marquee = ""
    var marqueeOffset = 0           // in characters
    var kbps: Int?
    var kHz: Int?
    var windowActive = true
    var alwaysOnTop = false
    var doubleSize = false
    var visMode: VisMode = .bars
    var timeRemaining = false
    var playlistOpen = false        // lights the PL button
    var timeVisible = true          // false during the "paused" blink
    var pressed: Control?           // button held down (and the cursor still over it)
    var dragging: Control?          // slider being dragged
    var positionOverride: Double?   // 0…1 while seeking
    var bars = [Double](repeating: 0, count: 19)
    var peaks = [Double](repeating: 0, count: 19)
    var osc = [Int](repeating: 8, count: 76)
}

/// Composes the main window at 1× (275×116) from skin sprites.
final class MainRenderer {
    let width = Layout.size.w
    let height = Layout.size.h
    private let ctx: CGContext

    init() {
        ctx = CGContext(data: nil, width: Layout.size.w, height: Layout.size.h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
    }

    func render(skin: Skin, state s: RenderState) -> CGImage? {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(skin, Sprites.main, 0, 0)
        drawTitleBar(skin, s)
        drawClutter(skin, s)
        drawStatus(skin, s)
        drawTime(skin, s)
        drawVisualizer(skin, s)
        drawMarquee(skin, s)
        drawInfo(skin, s)
        drawSliders(skin, s)
        drawButtons(skin, s)
        return ctx.makeImage()
    }

    // MARK: Primitives (top-left coordinates)

    private func draw(_ skin: Skin, _ sprite: Sprite, _ x: Int, _ y: Int) {
        guard let img = skin.image(sprite) else { return }
        ctx.draw(img, in: CGRect(x: x, y: height - y - img.height, width: img.width, height: img.height))
    }

    private func fill(_ c: Color, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    private func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ body: () -> Void) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: height - y - h, width: w, height: h))
        body()
        ctx.restoreGState()
    }

    /// Draws text with the skin's TEXT.BMP font; each character is a 5×6 cell.
    private func text(_ skin: Skin, _ str: String, _ x: Int, _ y: Int) {
        for (i, cell) in PixelFont.cells(for: str).enumerated() {
            draw(skin, Sprites.textCell(cell.col, cell.row), x + i * 5, y)
        }
    }

    // MARK: Parts

    private func drawTitleBar(_ skin: Skin, _ s: RenderState) {
        draw(skin, s.windowActive ? Sprites.titleActive : Sprites.titleInactive, 0, 0)
        draw(skin, Sprites.options(s.pressed == .options), 6, 3)
        draw(skin, Sprites.minimize(s.pressed == .minimize), 244, 3)
        draw(skin, Sprites.shade(s.pressed == .shade), 254, 3)
        draw(skin, Sprites.close(s.pressed == .close), 264, 3)
    }

    private func drawClutter(_ skin: Skin, _ s: RenderState) {
        draw(skin, Sprites.clutter, 10, 22)
        let lit = [
            s.pressed == .clutterO, s.alwaysOnTop || s.pressed == .clutterA, s.pressed == .clutterI,
            s.doubleSize || s.pressed == .clutterD, s.pressed == .clutterV,
        ]
        for (k, on) in lit.enumerated() where on {
            draw(skin, Sprites.clutterLit(k), 10, 22 + Layout.clutterOffsets[k].y)
        }
    }

    private func drawStatus(_ skin: Skin, _ s: RenderState) {
        draw(skin, s.playback == .playing ? Sprites.working : Sprites.notWorking, 24, 28)
        switch s.playback {
        case .playing: draw(skin, Sprites.playing, 26, 28)
        case .paused: draw(skin, Sprites.paused, 26, 28)
        case .stopped: draw(skin, Sprites.stopped, 26, 28)
        }
    }

    private func drawTime(_ skin: Skin, _ s: RenderState) {
        guard s.playback != .stopped, s.timeVisible else { return }
        let t = s.timeRemaining ? max(0, s.duration - s.elapsed) : s.elapsed
        var total = Int(max(0, t))
        if total > 99 * 60 + 59 { total = 99 * 60 + 59 }
        let m = total / 60, sec = total % 60
        let ex = skin.hasNumsEx
        for (x, d) in [(48, m / 10), (60, m % 10), (78, sec / 10), (90, sec % 10)] {
            draw(skin, Sprites.digit(d, ex: ex), x, 26)
        }
        if s.timeRemaining {
            if ex { draw(skin, Sprites.minusEx, 38, 26) } else { draw(skin, Sprites.minusSmall, 38, 32) }
        }
    }

    private func drawVisualizer(_ skin: Skin, _ s: RenderState) {
        guard s.visMode != .off else { return }
        let vc = skin.visColors
        let x0 = 24, y0 = 43
        fill(vc[0], x0, y0, 76, 16)
        for y in stride(from: 1, to: 16, by: 2) {
            for x in stride(from: 1, to: 76, by: 2) { fill(vc[1], x0 + x, y0 + y, 1, 1) }
        }
        if s.visMode == .bars {
            for i in 0..<min(19, s.bars.count) {
                let bx = x0 + i * 4
                let h = max(0, min(16, Int(s.bars[i].rounded())))
                for row in (16 - h)..<16 { fill(vc[2 + row], bx, y0 + row, 3, 1) }
                let p = max(0, min(16, Int(s.peaks[i].rounded())))
                if p > 0 { fill(vc[23], bx, y0 + 16 - p, 3, 1) }
            }
        } else {
            var prev = s.osc.first ?? 8
            for x in 0..<min(76, s.osc.count) {
                let y = max(0, min(15, s.osc[x]))
                for row in min(prev, y)...max(prev, y) {
                    let idx = 18 + min(4, Int(abs(Double(row) - 7.5) / 2))
                    fill(vc[idx], x0 + x, y0 + row, 1, 1)
                }
                prev = y
            }
        }
    }

    private func drawMarquee(_ skin: Skin, _ s: RenderState) {
        var cells = PixelFont.cells(for: s.marquee)
        let visible = 31
        if cells.count > 30 {
            cells += PixelFont.cells(for: "  ***  ")
            let start = s.marqueeOffset % cells.count
            cells = (0..<visible).map { cells[(start + $0) % cells.count] }
        }
        clip(111, 27, 154, 6) {
            for (i, cell) in cells.prefix(visible).enumerated() {
                draw(skin, Sprites.textCell(cell.col, cell.row), 111 + i * 5, 27)
            }
        }
    }

    private func drawInfo(_ skin: Skin, _ s: RenderState) {
        if let kbps = s.kbps { text(skin, String(format: "%3d", min(999, kbps)), 111, 43) }
        if let khz = s.kHz { text(skin, String(format: "%2d", min(99, khz)), 156, 43) }
        let on = s.playback != .stopped
        draw(skin, Sprites.mono(false), 212, 41)
        draw(skin, Sprites.stereo(on), 239, 41)
    }

    private func drawSliders(_ skin: Skin, _ s: RenderState) {
        let vol = max(0, min(100, s.volume))
        draw(skin, Sprites.volume(frame: Int((Double(vol) / 100 * 27).rounded())), 107, 57)
        let vx = Layout.volumeSlider.x + Int((Double(vol) / 100 * Double(Layout.volumeSlider.travel)).rounded())
        draw(skin, Sprites.volumeThumb(s.dragging == .volume), vx, 58)

        let bal = max(-100, min(100, s.balance))
        draw(skin, Sprites.balance(frame: Int((Double(abs(bal)) / 100 * 27).rounded())), 177, 57)
        let bx = Layout.balanceSlider.x + Int((Double(bal + 100) / 200 * Double(Layout.balanceSlider.travel)).rounded())
        draw(skin, Sprites.balanceThumb(s.dragging == .balance), bx, 58)

        draw(skin, Sprites.posbar, 16, 72)
        if let frac = s.positionOverride ?? (s.playback != .stopped && s.duration > 0 ? s.elapsed / s.duration : nil) {
            let px = Layout.positionSlider.x + Int((max(0, min(1, frac)) * Double(Layout.positionSlider.travel)).rounded())
            draw(skin, Sprites.posThumb(s.dragging == .position), px, 72)
        }
    }

    private func drawButtons(_ skin: Skin, _ s: RenderState) {
        draw(skin, Sprites.eq(on: false, down: s.pressed == .eq), 219, 58)
        draw(skin, Sprites.pl(on: s.playlistOpen, down: s.pressed == .pl), 242, 58)
        for t in Layout.transport {
            draw(skin, Sprite(.cbuttons, t.sx, s.pressed == t.0 ? t.h : 0, t.w, t.h), t.x, t.y)
        }
        draw(skin, Sprites.shuffle(on: s.shuffle, down: s.pressed == .shuffle), 164, 89)
        draw(skin, Sprites.repeatButton(on: s.repeating, down: s.pressed == .repeatButton), 210, 89)
    }
}
