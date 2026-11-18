import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Command-line rendering helpers (no window server or Spotify needed).
enum Snapshot {
    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

    static let controls: [String: Control] = [
        "play": .play, "pause": .pause, "stop": .stop, "next": .next, "prev": .prev, "eject": .eject,
        "shuffle": .shuffle, "repeat": .repeatButton, "eq": .eq, "pl": .pl, "options": .options,
        "minimize": .minimize, "shade": .shade, "close": .close,
    ]

    /// The skin named by --skin, or the built-in one.
    static func loadSkin() -> Skin? {
        guard let p = arg("--skin") else { return Skin.builtIn }
        do { return try Skin.load(from: URL(fileURLWithPath: p)) } catch {
            fputs("Retroamp: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    static var scale: Int { max(1, min(4, Int(arg("--scale") ?? "2") ?? 2)) }

    static func render(to path: String) -> Int32 {
        guard let skin = loadSkin() else { return 1 }
        let scale = self.scale
        var s = RenderState()
        s.playback = ["paused": PlaybackState.paused, "stopped": .stopped][arg("--state") ?? ""] ?? .playing
        s.elapsed = 83
        s.duration = 225
        s.volume = 72
        s.shuffle = true
        s.marquee = arg("--text") ?? "The Pixel Orchestra - Neon Highway (3:45)"
        s.marqueeOffset = Int(arg("--offset") ?? "0") ?? 0
        s.kHz = s.playback == .stopped ? nil : 44
        s.windowActive = !flag("--inactive")
        s.doubleSize = scale > 1
        s.alwaysOnTop = flag("--on-top")
        s.visMode = ["osc": VisMode.oscilloscope, "off": .off][arg("--vis") ?? ""] ?? .bars
        s.timeRemaining = flag("--remaining")
        s.pressed = arg("--press").flatMap { controls[$0] }
        s.playlistOpen = flag("--with-playlist")
        let a = Analyzer()
        a.loadDemo()
        s.bars = a.bars
        s.peaks = a.peaks
        s.osc = a.osc
        guard let img = MainRenderer().render(skin: skin, state: s) else { return 1 }
        var out = scaled(img, scale)
        if flag("--with-playlist") {
            guard let pl = PlaylistRenderer().image(skin: skin, state: playlistState(), scale: scale) else { return 1 }
            out = stack(out, pl)
        }
        return write([out], to: path, type: .png) ? 0 : 1
    }

    // MARK: Playlist editor

    static let menus: [String: PlaylistMenu] = ["add": .add, "rem": .remove, "sel": .select, "misc": .misc, "list": .list]

    /// Made-up artists and titles for screenshots.
    static let demoTracks: [(String, Double)] = [
        ("The Pixel Orchestra - Neon Highway", 225), ("Static Bloom - Cassette Summer", 198),
        ("Lo-Fi Lighthouse - Harbour Lights", 251), ("Velvet Circuit - Midnight Arcade", 312),
        ("Analog Hearts - Tape Delay", 187), ("Northern Relay - Signal Lost", 264),
        ("Moss & Marble - Quiet Rooms (Extended Version)", 642), ("The Dial Tones - Busy Signal", 159),
        ("Sundial Club - Late Bloomer", 233), ("Paper Satellites - Low Orbit", 289),
        ("Glasshouse Radio - Warm Static", 206), ("Cobalt Avenue - Overpass", 245),
        ("Ember Lane - Slow Burn", 298), ("Quiet Machines - Fan Noise", 174),
    ]

    /// Options: --size cols,rows  --inactive  --not-connected  --select 1,4 (row numbers)
    ///          --scroll n  --menu add|rem|sel|misc|list  --hover i  --pl-press close|shade  --handle-pressed
    static func playlistState() -> PlaylistRenderState {
        var s = PlaylistRenderState()
        let size = (arg("--size") ?? "0,4").split(separator: ",").compactMap { Int($0) }
        s.geometry = PlaylistGeometry(cols: max(0, size.first ?? 0), rows: max(0, size.count > 1 ? size[1] : 4))
        s.active = !flag("--inactive")
        if flag("--not-connected") {
            s.entries = PlaylistEntry.notConnected
            s.numbered = false
        } else {
            s.entries = demoTracks.map { PlaylistEntry(kind: .track, title: $0.0, duration: $0.1) }
            s.current = 0
            s.selection = Set((arg("--select") ?? "4").split(separator: ",").compactMap { Int($0) }.map { $0 - 1 })
        }
        s.offset = Int(arg("--scroll") ?? "0") ?? 0
        s.openMenu = arg("--menu").flatMap { menus[$0] }
        s.menuHover = arg("--hover").flatMap { Int($0) }
        s.pressed = ["close": PlaylistHit.close, "shade": .shade][arg("--pl-press") ?? ""]
        s.handlePressed = flag("--handle-pressed")
        if !flag("--not-connected") {
            let total = s.entries.compactMap(\.duration).reduce(0, +)
            let selected = s.selection.filter { s.entries.indices.contains($0) }.compactMap { s.entries[$0].duration }.reduce(0, +)
            s.runningTime = PlaylistEntry.longTimeString(selected) + "/" + PlaylistEntry.longTimeString(total)
            s.miniTime = flag("--remaining") ? "-0222" : " 0123"
        }
        return s
    }

    static func renderPlaylist(to path: String) -> Int32 {
        guard let skin = loadSkin(),
              let img = PlaylistRenderer().image(skin: skin, state: playlistState(), scale: scale) else { return 1 }
        return write([img], to: path, type: .png) ? 0 : 1
    }

    /// Puts one image on top of another, left-aligned.
    static func stack(_ top: CGImage, _ bottom: CGImage) -> CGImage {
        let w = max(top.width, bottom.width), h = top.height + bottom.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return top }
        ctx.draw(top, in: CGRect(x: 0, y: bottom.height, width: top.width, height: top.height))
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
        return ctx.makeImage() ?? top
    }

    /// Writes each sprite sheet as a PNG: the built-in skin's, or those of --skin.
    static func dumpSheets(to dir: String) -> Int32 {
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var sheets: [(SheetName, CGImage)] = DefaultSkin.makeSheets().map { ($0.key, $0.value) }
        if arg("--skin") != nil {
            guard let skin = loadSkin() else { return 1 }
            sheets = SheetName.allCases.compactMap { n in skin.sheet(n).map { (n, $0) } }
        }
        for (name, img) in sheets {
            guard write([scaled(img, scale)], to: base.appendingPathComponent("\(name.rawValue).png").path, type: .png) else { return 1 }
        }
        return 0
    }

    /// Nearest-neighbour upscale.
    static func scaled(_ img: CGImage, _ factor: Int) -> CGImage {
        guard factor > 1 else { return img }
        let w = img.width * factor, h = img.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func write(_ images: [CGImage], to path: String, type: UTType) -> Bool {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, type.identifier as CFString, images.count, nil) else { return false }
        for img in images { CGImageDestinationAddImage(dest, img, nil) }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: App icon

    static func makeIcon(to path: String) -> Int32 {
        let images = [16, 32, 64, 128, 256, 512, 1024].compactMap(icon)
        return write(images, to: path, type: .icns) ? 0 : 1
    }

    /// Chassis-coloured squircle with an LCD panel and a little spectrum.
    static func icon(_ size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let u = CGFloat(size) / 1024
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: y * u, width: w * u, height: h * u) }
        func round(_ r: CGRect, _ radius: CGFloat, _ c: Color) {
            ctx.setFillColor(c.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius * u, cornerHeight: radius * u, transform: nil))
            ctx.fillPath()
        }
        round(rect(100, 100, 824, 824), 185, Pal.chassisLight)
        round(rect(108, 108, 808, 808), 178, Pal.chassis)
        for (i, c) in [Pal.amber, Pal.amberDark, Pal.amber].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect(250, 800 - CGFloat(i) * 26, 524, 12))
        }
        round(rect(200, 220, 624, 520), 48, Pal.lcd)
        let heights = [6, 11, 15, 9, 13, 7, 4]
        let colors = DefaultSkin.visColors
        for (i, h) in heights.enumerated() {
            let x = 252 + CGFloat(i) * 76
            for row in 0..<h {
                ctx.setFillColor(colors[17 - row].cgColor)
                ctx.fill(rect(x, 262 + CGFloat(row) * 28, 56, 20))
            }
            ctx.setFillColor(Pal.peak.cgColor)
            ctx.fill(rect(x, 262 + CGFloat(h + 1) * 28, 56, 10))
        }
        return ctx.makeImage()
    }
}
