import CoreGraphics
import Foundation
import ImageIO

/// Sprite sheets of a classic skin (file names without extension).
enum SheetName: String, CaseIterable {
    case main, titlebar, cbuttons, shufrep, posbar, volume, balance, monoster, playpaus, numbers
    case numsEx = "nums_ex"
    case text, pledit
}

/// PLEDIT.TXT: colours and font of the playlist editor's track list.
struct PlaylistStyle {
    var normal: Color
    var current: Color
    var normalBG: Color
    var selectedBG: Color
    var font: String

    /// Used when a skin has a PLEDIT.BMP but no PLEDIT.TXT (classic default).
    static let classic = PlaylistStyle(normal: Color(0x00FF00), current: Color(0xFFFFFF),
                                       normalBG: Color(0x000000), selectedBG: Color(0x0000FF), font: "Arial")

    /// Reads the [Text] section. Values may lack the "#" or have extra characters, as Winamp allows.
    static func parse(_ text: String, base: PlaylistStyle) -> PlaylistStyle {
        var out = base
        var inText = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inText = line.lowercased().hasPrefix("[text]")
                continue
            }
            guard inText, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "normal": out.normal = color(value) ?? out.normal
            case "current": out.current = color(value) ?? out.current
            case "normalbg": out.normalBG = color(value) ?? out.normalBG
            case "selectedbg": out.selectedBG = color(value) ?? out.selectedBG
            case "font": if !value.isEmpty { out.font = String(value.prefix(64)) }
            default: break
            }
        }
        return out
    }

    private static func color(_ value: String) -> Color? {
        let hex = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        guard hex.count >= 6, let v = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return Color(v)
    }
}

/// A rectangle on a sprite sheet, in sheet pixels with a top-left origin.
struct Sprite: Hashable {
    let sheet: SheetName
    let x: Int, y: Int, w: Int, h: Int
    init(_ sheet: SheetName, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.sheet = sheet; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

enum SkinError: LocalizedError {
    case unreadable(String), notASkin

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Could not open the skin (\(why))."
        case .notASkin: return "This file has no MAIN.BMP, so it isn't a classic skin. Modern .wal skins aren't supported."
        }
    }
}

final class Skin {
    let name: String
    let visColors: [Color]
    let hasNumsEx: Bool
    let playlistStyle: PlaylistStyle
    private let sheets: [SheetName: CGImage]
    private let fallback: [SheetName: CGImage]
    private var cache: [Sprite: CGImage] = [:]

    static let builtIn: Skin = {
        let sheets = DefaultSkin.makeSheets()
        return Skin(name: "Retroamp", sheets: sheets, fallback: sheets, visColors: DefaultSkin.visColors,
                    playlistStyle: DefaultSkin.playlistStyle)
    }()

    private init(name: String, sheets: [SheetName: CGImage], fallback: [SheetName: CGImage], visColors: [Color],
                 playlistStyle: PlaylistStyle) {
        self.name = name
        self.sheets = sheets
        self.fallback = fallback
        self.visColors = visColors
        self.playlistStyle = playlistStyle
        hasNumsEx = sheets[.numsEx] != nil
    }

    /// The skin's own copy of a sheet (nil when it falls back to the built-in one).
    func sheet(_ name: SheetName) -> CGImage? { sheets[name] }

    var isBuiltIn: Bool { self === Skin.builtIn }

    /// Crops a sprite, falling back to the built-in skin when the sheet is missing or too small.
    func image(_ s: Sprite) -> CGImage? {
        if let hit = cache[s] { return hit }
        var sheet = sheets[s.sheet]
        if sheet == nil, s.sheet == .balance { sheet = sheets[.volume] }  // classic behaviour
        var img = sheet.flatMap { Skin.crop($0, s) }
        if img == nil, let fb = fallback[s.sheet] ?? fallback[.numbers] { img = Skin.crop(fb, s) }
        cache[s] = img
        return img
    }

    private static func crop(_ sheet: CGImage, _ s: Sprite) -> CGImage? {
        guard s.x >= 0, s.y >= 0, s.x + s.w <= sheet.width, s.y + s.h <= sheet.height else { return nil }
        return sheet.cropping(to: CGRect(x: s.x, y: s.y, width: s.w, height: s.h))
    }

    // MARK: Loading

    /// Loads a classic skin from a .wsz/.zip archive (read in memory) or an unpacked folder.
    static func load(from url: URL, name displayName: String? = nil) throws -> Skin {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw SkinError.unreadable("file not found") }

        // Index files by lower-cased name. Skins are often zipped with a top-level folder, so the
        // shallowest match wins.
        var files: [String: (depth: Int, read: () -> Data?)] = [:]
        func add(_ path: String, _ read: @escaping () -> Data?) {
            let parts = path.split(separator: "/")
            guard let last = parts.last, !last.hasPrefix("."), !parts.contains("__MACOSX") else { return }
            let key = last.lowercased()
            if let old = files[key], old.depth <= parts.count { return }
            files[key] = (parts.count, read)
        }

        if isDir.boolValue {
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let f = walker?.nextObject() as? URL {
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                add(f.path, { try? Data(contentsOf: f) })
            }
        } else {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw SkinError.unreadable("can't read the file") }
            guard let zip = ZipArchive(data) else { throw SkinError.unreadable("not a zip archive") }
            for e in zip.entries where !e.name.hasSuffix("/") {
                add(e.name.replacingOccurrences(of: "\\", with: "/"), { zip.contents(of: e) })
            }
        }

        var sheets: [SheetName: CGImage] = [:]
        for name in SheetName.allCases {
            for ext in ["bmp", "png"] {
                if let data = files["\(name.rawValue).\(ext)"]?.read(), let img = loadImage(data) {
                    sheets[name] = img
                    break
                }
            }
        }
        guard sheets[.main] != nil else { throw SkinError.notASkin }

        var vis = DefaultSkin.visColors
        if let data = files["viscolor.txt"]?.read() {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            for (i, c) in parseVisColors(text).prefix(24).enumerated() { vis[i] = c }
        }
        // Without its own PLEDIT.BMP a skin borrows the built-in playlist art, so keep its colours too.
        var style = sheets[.pledit] != nil ? PlaylistStyle.classic : DefaultSkin.playlistStyle
        if let data = files["pledit.txt"]?.read() {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            style = PlaylistStyle.parse(text, base: style)
        }
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        return Skin(name: name, sheets: sheets, fallback: Skin.builtIn.sheets, visColors: vis, playlistStyle: style)
    }

    /// Decodes an image fully into memory as an opaque RGBA bitmap (classic skins have no alpha).
    private static func loadImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0, w < 4096, h < 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// VISCOLOR.TXT: one "r,g,b" triple per line, optional "//" comments.
    static func parseVisColors(_ text: String) -> [Color] {
        var out: [Color] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.components(separatedBy: "//")[0]
            let nums = content.split(whereSeparator: { !("0"..."9").contains($0) }).compactMap { Int($0) }
            guard nums.count >= 3 else { continue }
            func ch(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
            out.append(Color(r: ch(nums[0]), g: ch(nums[1]), b: ch(nums[2])))
        }
        return out
    }
}
