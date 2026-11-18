import AppKit

/// Borderless playlist editor window. It takes keyboard focus but never becomes main, so the
/// player keeps that role.
final class PlaylistWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the playlist editor and turns mouse and keyboard input into controller calls.
/// Points are converted to skin pixels (top-left origin) before hit-testing.
final class PlaylistView: NSView {
    weak var controller: PlaylistController?
    var scale: CGFloat = 2

    /// Close/shade button held down (nil once the cursor leaves it).
    private(set) var pressed: PlaylistHit?
    private(set) var openMenu: PlaylistMenu?
    private(set) var menuHover: Int?
    private(set) var draggingScrollbar = false

    private enum Drag {
        case window(start: NSPoint, frame: NSRect)
        case resize(start: NSPoint, cols: Int, rows: Int)
        case scrollbar(grab: CGFloat)
        case button(PlaylistHit)
        /// `sticky`: the menu was just opened and the cursor hasn't left the entry over its button,
        /// so releasing keeps the menu open (click to open, click an entry to choose).
        case menu(PlaylistMenu, sticky: Bool, initial: Int?)
    }

    private var drag: Drag?
    private var scrollAccumulator: CGFloat = 0
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        c.renderer.draw(skin: c.app.skin, state: c.renderState(), in: ctx, scale: scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func skinPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: (bounds.height - p.y) / scale)
    }

    private func hit(_ p: CGPoint, menu: PlaylistMenu? = nil) -> PlaylistHit {
        guard let c = controller else { return .frame }
        return c.geometry.hit(p, openMenu: menu, rowCount: c.visibleRowCount)
    }

    private func menuEntry(_ m: PlaylistMenu, at p: CGPoint) -> Int? {
        if case .menuItem(m, let i) = hit(p, menu: m) { return i }
        return nil
    }

    func closeMenu() {
        guard openMenu != nil else { return }
        openMenu = nil
        menuHover = nil
        if case .menu = drag { drag = nil }
        needsDisplay = true
    }

    private func open(_ m: PlaylistMenu) {
        let last = m.items.count - 1  // the bottom entry sits over the button
        openMenu = m
        menuHover = last
        drag = .menu(m, sticky: true, initial: last)
        controller?.menuHovered(m, last)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard let c = controller, let window else { return }
        window.makeFirstResponder(self)
        let p = skinPoint(e)

        // An open menu takes the next click: an entry triggers on release, anything else closes it.
        if let m = openMenu {
            if let i = menuEntry(m, at: p) {
                menuHover = i
                drag = .menu(m, sticky: false, initial: i)
            } else {
                closeMenu()
                if case .menuButton(let other) = hit(p), other != m { open(other) }
            }
            needsDisplay = true
            return
        }

        let shift = e.modifierFlags.contains(.shift), command = e.modifierFlags.contains(.command)
        switch hit(p) {
        case .close: pressed = .close; drag = .button(.close)
        case .shade: pressed = .shade; drag = .button(.shade)
        case .menuButton(let m): open(m)
        case .menuItem: break
        case .miniTime, .scrollUp, .scrollDown, .action: drag = .button(hit(p))
        case .resize:
            drag = .resize(start: NSEvent.mouseLocation, cols: c.geometry.cols, rows: c.geometry.rows)
        case .scrollbar:
            let handle = c.handleRect
            var grab = p.y - handle.minY
            if !handle.contains(p) {
                grab = CGFloat(PlaylistGeometry.handleHeight) / 2
                c.scrollHandle(toTop: p.y - grab)
            }
            draggingScrollbar = true
            drag = .scrollbar(grab: grab)
        case .row(let i):
            let index = c.offset + i
            if e.clickCount == 2 { c.activate(index) } else { c.click(index, extend: shift, toggle: command) }
        case .listBackground:
            if !shift && !command { c.selectNone() }
        case .frame:
            if e.clickCount == 2, p.y < 14 { c.buttonClicked(.shade); break }
            drag = .window(start: NSEvent.mouseLocation, frame: window.frame)
            c.beginWindowDrag()
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller, let d = drag else { return }
        let p = skinPoint(e)
        switch d {
        case .window(let start, let frame):
            let now = NSEvent.mouseLocation
            var f = frame
            f.origin.x += now.x - start.x
            f.origin.y += now.y - start.y
            window?.setFrameOrigin(c.snapped(f).origin)
        case .resize(let start, let cols, let rows):
            let now = NSEvent.mouseLocation
            let dx = (now.x - start.x) / scale, dy = (start.y - now.y) / scale
            c.resize(cols: cols + Int((dx / CGFloat(PlaylistGeometry.step.w)).rounded()),
                     rows: rows + Int((dy / CGFloat(PlaylistGeometry.step.h)).rounded()))
        case .scrollbar(let grab):
            c.scrollHandle(toTop: p.y - grab)
        case .button(let h):
            if h == .close || h == .shade { pressed = hit(p) == h ? h : nil }
        case .menu(let m, let sticky, let initial):
            let hover = menuEntry(m, at: p)
            if hover != menuHover {
                menuHover = hover
                if let hover { c.menuHovered(m, hover) }
            }
            if sticky, hover != initial { drag = .menu(m, sticky: false, initial: initial) }
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = controller, let d = drag else { return }
        drag = nil
        let p = skinPoint(e)
        switch d {
        case .window: c.endWindowDrag()
        case .resize: c.endResize()
        case .scrollbar: draggingScrollbar = false
        case .button(let h):
            pressed = nil
            if hit(p) == h { c.buttonClicked(h) }
        case .menu(let m, let sticky, _):
            guard !sticky else { break }  // a plain click on the button leaves the menu open
            let chosen = menuEntry(m, at: p)
            closeMenu()
            if let chosen { c.menuChosen(m, chosen) }
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        guard let m = openMenu, drag == nil else { return }
        let hover = menuEntry(m, at: skinPoint(e))
        guard hover != menuHover else { return }
        menuHover = hover
        if let hover { controller?.menuHovered(m, hover) }
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        closeMenu()
        if case .row(let i) = hit(skinPoint(e)) { c.rightClicked(c.offset + i) }
        NSMenu.popUpContextMenu(c.contextMenu(), with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        guard let c = controller else { return }
        if e.hasPreciseScrollingDeltas {
            scrollAccumulator += e.scrollingDeltaY / (CGFloat(PlaylistGeometry.rowHeight) * scale)
        } else {
            scrollAccumulator += e.scrollingDeltaY * 3
        }
        let rows = Int(scrollAccumulator)
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows)
        c.scroll(by: -rows)
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return }
        if e.keyCode == 53, openMenu != nil { closeMenu(); return }
        if !c.key(e) { c.app.view.keyDown(with: e) }  // transport keys (Z X C V B …) work here too
    }

    /// ⌘A, ⌘C and ⌘V from the Edit menu.
    override func selectAll(_ sender: Any?) { controller?.selectAll() }
    @objc func copy(_ sender: Any?) { controller?.copyLinks() }
    @objc func paste(_ sender: Any?) { controller?.pasteToQueue() }
}
