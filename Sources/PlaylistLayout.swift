import CoreGraphics

/// The playlist editor's pop-up menus along the bottom edge (ADD, REM, SEL, MISC, LIST).
enum PlaylistMenu: Int, CaseIterable {
    case add, remove, select, misc, list

    /// Entries from top to bottom; the last one sits over the button itself.
    var items: [PlaylistMenuItem] {
        switch self {
        case .add: return [.addURL, .addDir, .addFile]
        case .remove: return [.removeMisc, .removeAll, .crop, .removeSelected]
        case .select: return [.invertSelection, .selectZero, .selectAll]
        case .misc: return [.sortList, .fileInfo, .miscOptions]
        case .list: return [.newList, .saveList, .loadList]
        }
    }

    var bar: Sprite {
        switch self {
        case .add: return Sprite(.pledit, 48, 111, 3, 54)
        case .remove: return Sprite(.pledit, 100, 111, 3, 72)
        case .select: return Sprite(.pledit, 150, 111, 3, 54)
        case .misc: return Sprite(.pledit, 200, 111, 3, 54)
        case .list: return Sprite(.pledit, 250, 111, 3, 54)
        }
    }
}

enum PlaylistMenuItem {
    case addURL, addDir, addFile
    case removeMisc, removeAll, crop, removeSelected
    case invertSelection, selectZero, selectAll
    case sortList, fileInfo, miscOptions
    case newList, saveList, loadList

    /// Normal sprite; the highlighted one is 23 px to the right.
    private var origin: (x: Int, y: Int) {
        switch self {
        case .addURL: return (0, 111)
        case .addDir: return (0, 130)
        case .addFile: return (0, 149)
        case .removeAll: return (54, 111)
        case .crop: return (54, 130)
        case .removeSelected: return (54, 149)
        case .removeMisc: return (54, 168)
        case .invertSelection: return (104, 111)
        case .selectZero: return (104, 130)
        case .selectAll: return (104, 149)
        case .sortList: return (154, 111)
        case .fileInfo: return (154, 130)
        case .miscOptions: return (154, 149)
        case .newList: return (204, 111)
        case .saveList: return (204, 130)
        case .loadList: return (204, 149)
        }
    }

    func sprite(hover: Bool) -> Sprite {
        let o = origin
        return Sprite(.pledit, o.x + (hover ? 23 : 0), o.y, 22, 18)
    }
}

/// Clickable parts of the playlist editor.
enum PlaylistHit: Equatable {
    case close, shade
    case menuButton(PlaylistMenu)
    case menuItem(PlaylistMenu, Int)
    case action(Int)            // mini transport: prev, play, pause, stop, next, eject
    case miniTime
    case scrollUp, scrollDown
    case resize
    case scrollbar
    case row(Int)               // visible row
    case listBackground         // the track area below the last row
    case frame                  // anything else drags the window
}

/// Classic playlist editor geometry (top-left origin, skin pixels), following the classic
/// skin format as documented by Webamp (MIT). The window grows in 25×29 steps from 275×116.
struct PlaylistGeometry: Equatable {
    var cols: Int   // extra 25 px width segments
    var rows: Int   // extra 29 px height segments

    static let minSize = (w: 275, h: 116)
    static let step = (w: 25, h: 29)
    static let rowHeight = 13

    var width: Int { Self.minSize.w + Self.step.w * cols }
    var height: Int { Self.minSize.h + Self.step.h * rows }
    var visibleRows: Int { (58 + Self.step.h * rows) / Self.rowHeight }

    /// The track list, inside the frame.
    var list: CGRect { r(12, 20, width - 32, height - 58) }
    func rowRect(_ i: Int) -> CGRect { r(12, 23 + Self.rowHeight * i, width - 32, Self.rowHeight) }

    var close: CGRect { r(width - 11, 3, 9, 9) }
    var shade: CGRect { r(width - 21, 3, 9, 9) }

    /// Spacers show when the width is an even number of segments, so the title stays centred.
    var showSpacers: Bool { cols % 2 == 0 }
    var fillWidth: Int { showSpacers ? (width - 175) / 2 : (width - 150) / 2 }
    var titleX: Int { 25 + (showSpacers ? 12 : 0) + fillWidth }

    var scrollTrack: CGRect { r(width - 15, 20, 8, height - 58) }
    static let handleHeight = 18
    var handleTravel: Int { max(0, height - 58 - Self.handleHeight) }

    func menuButton(_ m: PlaylistMenu) -> CGRect {
        let x: Int
        switch m {
        case .add: x = 14
        case .remove: x = 43
        case .select: x = 72
        case .misc: x = 101
        case .list: x = width - 44
        }
        return r(x, height - 30, 22, 18)
    }

    func menuItem(_ m: PlaylistMenu, _ i: Int) -> CGRect {
        let b = menuButton(m)
        let count = m.items.count
        return CGRect(x: b.minX, y: b.minY - CGFloat((count - 1 - i) * 18), width: 22, height: 18)
    }

    func menuBar(_ m: PlaylistMenu) -> CGRect {
        let b = menuButton(m)
        let h = CGFloat(m.bar.h)
        return CGRect(x: b.minX - 3, y: b.maxY - h, width: 3, height: h)
    }

    var bottomRight: (x: Int, y: Int) { (width - 150, height - 38) }
    func action(_ i: Int) -> CGRect { r(bottomRight.x + 3 + 10 * i, bottomRight.y + 22, 10, 10) }
    var runningTime: (x: Int, y: Int) { (bottomRight.x + 7, bottomRight.y + 10) }
    /// Mini time characters: minus, m, m, s, s (the colon is part of the frame art).
    var miniTimeX: [Int] { [1, 7, 12, 20, 25].map { bottomRight.x + 66 + $0 } }
    var miniTimeY: Int { bottomRight.y + 23 }
    var miniTime: CGRect { r(bottomRight.x + 66, bottomRight.y + 23, 30, 6) }
    var scrollUp: CGRect { r(width - 15, height - 36, 8, 5) }
    var scrollDown: CGRect { r(width - 15, height - 30, 8, 5) }
    var resize: CGRect { r(width - 20, height - 20, 20, 20) }
    var showVisualizerArt: Bool { cols > 2 }

    /// Hit-tests a point. `openMenu` takes priority because it floats over the list.
    func hit(_ p: CGPoint, openMenu: PlaylistMenu?, rowCount: Int) -> PlaylistHit {
        if let m = openMenu {
            for i in m.items.indices where menuItem(m, i).contains(p) { return .menuItem(m, i) }
        }
        if close.contains(p) { return .close }
        if shade.contains(p) { return .shade }
        for m in PlaylistMenu.allCases where menuButton(m).contains(p) { return .menuButton(m) }
        for i in 0..<6 where action(i).contains(p) { return .action(i) }
        if miniTime.contains(p) { return .miniTime }
        if scrollUp.contains(p) { return .scrollUp }
        if scrollDown.contains(p) { return .scrollDown }
        if resize.contains(p) { return .resize }
        if scrollTrack.contains(p) { return .scrollbar }
        if list.contains(p) {
            let i = Int((p.y - 23) / CGFloat(Self.rowHeight))
            if p.y >= 23, i < min(visibleRows, rowCount) { return .row(i) }
            return .listBackground
        }
        return .frame
    }

    private func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// PLEDIT.BMP sprite rectangles.
enum PlaylistSprites {
    static func topLeft(_ active: Bool) -> Sprite { Sprite(.pledit, 0, active ? 0 : 21, 25, 20) }
    static func title(_ active: Bool) -> Sprite { Sprite(.pledit, 26, active ? 0 : 21, 100, 20) }
    static func topTile(_ active: Bool) -> Sprite { Sprite(.pledit, 127, active ? 0 : 21, 25, 20) }
    static func topRight(_ active: Bool) -> Sprite { Sprite(.pledit, 153, active ? 0 : 21, 25, 20) }
    static let leftTile = Sprite(.pledit, 0, 42, 12, 29)
    static let rightTile = Sprite(.pledit, 31, 42, 20, 29)
    static let bottomTile = Sprite(.pledit, 179, 0, 25, 38)
    static let bottomLeft = Sprite(.pledit, 0, 72, 125, 38)
    static let bottomRight = Sprite(.pledit, 126, 72, 150, 38)
    static let visualizer = Sprite(.pledit, 205, 0, 75, 38)
    static func handle(_ pressed: Bool) -> Sprite { Sprite(.pledit, pressed ? 61 : 52, 53, 8, 18) }
    static let closePressed = Sprite(.pledit, 52, 42, 9, 9)
    static let shadePressed = Sprite(.pledit, 62, 42, 9, 9)
}
