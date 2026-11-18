import CoreGraphics

/// Clickable parts of the main window.
enum Control {
    case options, minimize, shade, close
    case clutterO, clutterA, clutterI, clutterD, clutterV
    case visualizer, time, marquee
    case logo                               // the Winamp logo: Retroamp's DJ button
    case volume, balance, eq, pl, position
    case prev, play, pause, stop, next, eject
    case repeatButton, shuffle
}

/// Classic main-window geometry (275×116, top-left origin). Coordinates follow the
/// classic skin format as documented by Webamp (MIT licence).
enum Layout {
    static let size = (w: 275, h: 116)

    static let clutterOffsets: [(y: Int, h: Int)] = [(3, 8), (11, 7), (18, 7), (25, 8), (33, 7)]

    static let transport: [(Control, x: Int, y: Int, sx: Int, w: Int, h: Int)] = [
        (.prev, 16, 88, 0, 23, 18), (.play, 39, 88, 23, 23, 18), (.pause, 62, 88, 46, 23, 18),
        (.stop, 85, 88, 69, 23, 18), (.next, 108, 88, 92, 22, 18), (.eject, 136, 89, 114, 22, 16),
    ]

    /// Hit-test order matters: repeat overlaps shuffle by one pixel and wins.
    static let hitAreas: [(Control, CGRect)] = {
        var a: [(Control, CGRect)] = [
            (.options, r(6, 3, 9, 9)), (.minimize, r(244, 3, 9, 9)), (.shade, r(254, 3, 9, 9)),
            (.close, r(264, 3, 9, 9)),
        ]
        let clutter: [Control] = [.clutterO, .clutterA, .clutterI, .clutterD, .clutterV]
        for (i, c) in clutter.enumerated() {
            a.append((c, r(10, 22 + clutterOffsets[i].y, 8, clutterOffsets[i].h)))
        }
        a += [
            (.visualizer, r(24, 43, 76, 16)), (.time, r(36, 26, 63, 13)), (.marquee, r(111, 24, 154, 12)),
            (.volume, r(107, 57, 68, 13)), (.balance, r(177, 57, 38, 13)),
            (.eq, r(219, 58, 23, 12)), (.pl, r(242, 58, 23, 12)), (.position, r(16, 72, 248, 10)),
        ]
        for t in transport { a.append((t.0, r(t.x, t.y, t.w, t.h))) }
        a += [(.repeatButton, r(210, 89, 28, 15)), (.shuffle, r(164, 89, 47, 15)), (.logo, r(253, 91, 13, 15))]
        return a
    }()

    static func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    static func hit(_ p: CGPoint) -> Control? { hitAreas.first { $0.1.contains(p) }?.0 }

    static func rect(_ c: Control) -> CGRect { hitAreas.first { $0.0 == c }?.1 ?? .zero }

    // Slider geometry: (left edge, thumb width, thumb travel).
    static let volumeSlider = (x: 107, thumb: 14, travel: 51)
    static let balanceSlider = (x: 177, thumb: 14, travel: 24)
    static let positionSlider = (x: 16, thumb: 29, travel: 219)
}

/// Sprite rectangles on the classic sheets.
enum Sprites {
    static let main = Sprite(.main, 0, 0, 275, 116)
    static let titleActive = Sprite(.titlebar, 27, 0, 275, 14)
    static let titleInactive = Sprite(.titlebar, 27, 15, 275, 14)
    static func options(_ down: Bool) -> Sprite { Sprite(.titlebar, 0, down ? 9 : 0, 9, 9) }
    static func minimize(_ down: Bool) -> Sprite { Sprite(.titlebar, 9, down ? 9 : 0, 9, 9) }
    static func shade(_ down: Bool) -> Sprite { Sprite(.titlebar, down ? 9 : 0, 18, 9, 9) }
    static func close(_ down: Bool) -> Sprite { Sprite(.titlebar, 18, down ? 9 : 0, 9, 9) }
    static let clutter = Sprite(.titlebar, 304, 0, 8, 43)
    static func clutterLit(_ k: Int) -> Sprite {
        let o = Layout.clutterOffsets[k]
        return Sprite(.titlebar, 304 + 8 * k, 44 + o.y, 8, o.h)
    }

    static let playing = Sprite(.playpaus, 0, 0, 9, 9)
    static let paused = Sprite(.playpaus, 9, 0, 9, 9)
    static let stopped = Sprite(.playpaus, 18, 0, 9, 9)
    static let notWorking = Sprite(.playpaus, 36, 0, 3, 9)
    static let working = Sprite(.playpaus, 39, 0, 3, 9)

    static func digit(_ n: Int, ex: Bool) -> Sprite { Sprite(ex ? .numsEx : .numbers, n * 9, 0, 9, 13) }
    static let minusSmall = Sprite(.numbers, 20, 6, 5, 1)
    static let minusEx = Sprite(.numsEx, 99, 0, 9, 13)

    static func textCell(_ col: Int, _ row: Int) -> Sprite { Sprite(.text, col * 5, row * 6, 5, 6) }

    static func stereo(_ on: Bool) -> Sprite { Sprite(.monoster, 0, on ? 0 : 12, 29, 12) }
    static func mono(_ on: Bool) -> Sprite { Sprite(.monoster, 29, on ? 0 : 12, 27, 12) }

    static func volume(frame: Int) -> Sprite { Sprite(.volume, 0, frame * 15, 68, 13) }
    static func volumeThumb(_ down: Bool) -> Sprite { Sprite(.volume, down ? 0 : 15, 422, 14, 11) }
    static func balance(frame: Int) -> Sprite { Sprite(.balance, 9, frame * 15, 38, 13) }
    static func balanceThumb(_ down: Bool) -> Sprite { Sprite(.balance, down ? 0 : 15, 422, 14, 11) }

    static let posbar = Sprite(.posbar, 0, 0, 248, 10)
    static func posThumb(_ down: Bool) -> Sprite { Sprite(.posbar, down ? 278 : 248, 0, 29, 10) }

    static func shuffle(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, 28, (on ? 30 : 0) + (down ? 15 : 0), 47, 15) }
    static func repeatButton(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, 0, (on ? 30 : 0) + (down ? 15 : 0), 28, 15) }
    static func eq(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, down ? 46 : 0, on ? 73 : 61, 23, 12) }
    static func pl(on: Bool, down: Bool) -> Sprite { Sprite(.shufrep, down ? 69 : 23, on ? 73 : 61, 23, 12) }
}
