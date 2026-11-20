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
    /// REGION.TXT's main-window shape: opaque inside, transparent outside (nil: a plain rectangle).
    let regionMask: CGImage?
    private let sheets: [SheetName: CGImage]
    private let fallback: [SheetName: CGImage]
    private var cache: [Sprite: CGImage] = [:]

    static let builtIn: Skin = {
        let sheets = DefaultSkin.makeSheets()
        return Skin(name: "Retroamp", sheets: sheets, fallback: sheets, visColors: DefaultSkin.visColors,
                    playlistStyle: DefaultSkin.playlistStyle, regionMask: nil)
    }()

    /// What a skin's missing sheets are drawn from: the Winamp base skin once it's downloaded, as in
    /// Winamp and Webamp, otherwise the built-in skin.
    private static var baseSheets: [SheetName: CGImage]?
    private static var fallbackSheets: [SheetName: CGImage] {
        if baseSheets == nil, FileManager.default.fileExists(atPath: ClassicSkin.fileURL.path) {
            baseSheets = ClassicSkin.loadCached()?.sheets
        }
        return baseSheets ?? builtIn.sheets
    }

    private init(name: String, sheets: [SheetName: CGImage], fallback: [SheetName: CGImage], visColors: [Color],
                 playlistStyle: PlaylistStyle, regionMask: CGImage?) {
        self.name = name
        self.sheets = sheets
        self.fallback = fallback
        self.visColors = visColors
        self.playlistStyle = playlistStyle
        self.regionMask = regionMask
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

    /// The sprite's pixels. When a sheet is smaller than the format says, the part of a sprite that
    /// lies off it is transparent, as in Winamp and Webamp; only a sprite wholly off it falls back.
    private static func crop(_ sheet: CGImage, _ s: Sprite) -> CGImage? {
        let r = CGRect(x: s.x, y: s.y, width: s.w, height: s.h)
        let visible = r.intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        guard !visible.isEmpty, let part = sheet.cropping(to: visible) else { return nil }
        if visible == r { return part }
        guard let ctx = CGContext(data: nil, width: s.w, height: s.h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin in the sprite, bottom-left in the context.
        ctx.draw(part, in: CGRect(x: visible.minX - r.minX, y: r.maxY - visible.maxY, width: visible.width, height: visible.height))
        return ctx.makeImage()
    }

    // MARK: Loading

    /// Loads a classic skin from a .wsz/.zip archive (read in memory) or an unpacked folder.
    /// `isBase` loads the Winamp base skin itself, whose few gaps the built-in skin fills.
    static func load(from url: URL, name displayName: String? = nil, isBase: Bool = false) throws -> Skin {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw SkinError.unreadable("file not found") }

        // Index files by lower-cased name. Skins are often zipped with a top-level folder, so the
        // shallowest match wins. Between equals ("cbuttons.bmp" and "cButtons.bmp") the later one
        // does, as Winamp unzipping onto a case-insensitive disk ended up with it, and as Webamp does.
        var files: [String: (depth: Int, read: () -> Data?)] = [:]
        func add(_ path: String, _ read: @escaping () -> Data?) {
            let parts = path.split(separator: "/")
            guard let last = parts.last, !last.hasPrefix("."), !parts.contains("__MACOSX") else { return }
            let key = last.lowercased()
            if let old = files[key], old.depth < parts.count { return }
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
        let fallback = isBase ? Skin.builtIn.sheets : Skin.fallbackSheets
        // Without its own PLEDIT.BMP a skin borrows the fallback's playlist art, so its colours too.
        let borrowsBuiltIn = sheets[.pledit] == nil && fallback[.pledit] === Skin.builtIn.sheets[.pledit]
        var style = borrowsBuiltIn ? DefaultSkin.playlistStyle : PlaylistStyle.classic
        if let data = files["pledit.txt"]?.read() {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            style = PlaylistStyle.parse(text, base: style)
        }
        var mask: CGImage?
        if let data = files["region.txt"]?.read() {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            mask = regionMask(parseRegion(text)["normal"] ?? [], width: Layout.size.w, height: Layout.size.h)
        }
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        return Skin(name: name, sheets: sheets, fallback: fallback, visColors: vis, playlistStyle: style, regionMask: mask)
    }

    // MARK: REGION.TXT

    /// Polygons per section (lower-cased: "normal", "windowshade", "equalizer"…), in skin pixels
    /// with a top-left origin. As Webamp's regionParser: NumPoints lists each polygon's size,
    /// PointList the x,y pairs separated by commas or spaces; polygons under 3 points are skipped.
    /// Unlike Webamp, a polygon that runs out of points is dropped too: in Webamp it hides the
    /// whole window (Game_Boy_Advance_Amp.wsz lists 6 points and gives 5½).
    static func parseRegion(_ text: String) -> [String: [[CGPoint]]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                current = line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let section = current, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...]
            if let second = value.firstIndex(of: "=") { value = value[..<second] }  // as Webamp: ignore a second "="
            sections[section, default: [:]][key] = value.trimmingCharacters(in: .whitespaces)
        }
        var out: [String: [[CGPoint]]] = [:]
        for (name, keys) in sections {
            guard let counts = keys["numpoints"], let list = keys["pointlist"] else { continue }
            let numbers = list.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            var points: [CGPoint] = []
            var i = 0
            while i + 1 < numbers.count { points.append(CGPoint(x: numbers[i], y: numbers[i + 1])); i += 2 }
            var at = 0
            var polygons: [[CGPoint]] = []
            for n in counts.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                defer { at += max(0, n) }
                guard n >= 3, at + n <= points.count else { continue }
                polygons.append(Array(points[at..<(at + n)]))
            }
            if !polygons.isEmpty { out[name] = polygons }
        }
        return out
    }

    /// The union of the polygons as an RGBA image, opaque inside and clear outside.
    static func regionMask(_ polygons: [[CGPoint]], width: Int, height: Int) -> CGImage? {
        guard !polygons.isEmpty,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(false)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for p in polygons {
            ctx.beginPath()
            ctx.addLines(between: p)
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    /// Decodes an image fully into memory as an opaque RGBA bitmap (classic skins have no alpha).
    private static func loadImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              var img = CGImageSourceCreateImageAtIndex(src, 0, nil) ?? retryBMP(data) else { return nil }
        if data.starts(with: [0x42, 0x4D]) { img = ignoringAlpha(img) }
        let w = img.width, h = img.height
        guard w > 0, h > 0, w < 4096, h < 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Winamp ignores the fourth byte of a 32-bit BMP. ImageIO's image reports it as padding but
    /// draws it as alpha, so a skin whose padding bytes are 0 came out black. Rebuilds the image
    /// from its decoded bytes with that byte as padding.
    private static func ignoringAlpha(_ img: CGImage) -> CGImage {
        guard img.bitsPerPixel == 32, img.bitsPerComponent == 8, let space = img.colorSpace,
              let bytes = img.dataProvider?.data, let provider = CGDataProvider(data: bytes) else { return img }
        let skip: CGImageAlphaInfo
        switch img.alphaInfo {
        case .last, .noneSkipLast: skip = .noneSkipLast
        case .first, .noneSkipFirst: skip = .noneSkipFirst
        default: return img  // premultiplied: the colours are already gone
        }
        let info = (img.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | skip.rawValue
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) ?? img
    }

    /// ImageIO refuses BMPs whose header lists "important colours" (or a palette size) that a
    /// true-colour image doesn't have; Windows and browsers ignore those fields. Clears them.
    private static func retryBMP(_ data: Data) -> CGImage? {
        guard data.count > 54, data[0] == 0x42, data[1] == 0x4D else { return nil }
        var b = [UInt8](data)
        let headerSize = Int(b[14]) | Int(b[15]) << 8
        let bpp = Int(b[28]) | Int(b[29]) << 8
        guard headerSize >= 40 else { return nil }
        for i in 50..<54 { b[i] = 0 }                  // biClrImportant
        if bpp > 8 { for i in 46..<50 { b[i] = 0 } }   // biClrUsed
        guard let src = CGImageSourceCreateWithData(Data(b) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
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
