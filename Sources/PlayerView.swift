import AppKit

/// Borderless window that can still become key (for keyboard shortcuts).
final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum SliderPhase { case began, changed, ended }

/// Draws the skinned main window and turns mouse/keyboard input into player actions.
/// Coordinates are converted to skin pixels (275×116, top-left origin) before hit-testing.
final class PlayerView: NSView {
    weak var controller: AppDelegate?
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            updateToolTips()
        }
    }

    /// Button under the mouse while it is held down (nil once the cursor leaves it).
    private(set) var pressed: Control?
    /// Slider currently being dragged.
    private(set) var dragging: Control?
    private var held: Control?
    private var scrollAccumulator: CGFloat = 0
    private var resizing: (edge: ResizeEdge, mouse: NSPoint, frame: NSRect)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
        updateToolTips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    /// The Winamp logo is the DJ button, which isn't obvious, so it gets a tool tip.
    private func updateToolTips() {
        removeAllToolTips()
        let r = Layout.rect(.logo)
        addToolTip(NSRect(x: r.minX * scale, y: bounds.height - r.maxY * scale,
                          width: r.width * scale, height: r.height * scale), owner: self, userData: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { controller?.skin.regionMask == nil }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = controller?.renderFrame() else { return }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: bounds)
    }

    private func skinPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: (bounds.height - p.y) / scale)
    }

    // MARK: Resizing

    /// The window is borderless, so AppKit doesn't resize it: dragging the bottom-right corner or
    /// the right or bottom edge scales the whole skin, from the original size up to 3×.
    enum ResizeEdge { case corner, right, bottom }

    /// In points, so they're as easy to hit at every size. They stay clear of the title bar
    /// buttons and of the Winamp logo, which ends 10 skin pixels above the bottom edge.
    private static let cornerSize: CGFloat = 10, edgeWidth: CGFloat = 3, titleBarHeight: CGFloat = 14

    var resizeZones: [(ResizeEdge, NSRect)] {
        let b = bounds, c = Self.cornerSize, w = Self.edgeWidth
        let belowTitle = b.height - Self.titleBarHeight * scale
        return [(.corner, NSRect(x: b.maxX - c, y: 0, width: c, height: c)),
                (.right, NSRect(x: b.maxX - w, y: c, width: w, height: max(0, belowTitle - c))),
                (.bottom, NSRect(x: 0, y: 0, width: max(0, b.width - c), height: w))]
    }

    func resizeEdge(at p: NSPoint) -> ResizeEdge? { resizeZones.first { $0.1.contains(p) }?.0 }

    private func cursor(for edge: ResizeEdge) -> NSCursor {
        if #available(macOS 15, *) {
            let largest = controller?.largestScale ?? AppDelegate.maxScale
            let directions: NSCursor.FrameResizeDirection.Set =
                scale <= 1 ? .outward : scale >= largest ? .inward : .all
            switch edge {
            case .corner: return .frameResize(position: .bottomRight, directions: directions)
            case .right: return .frameResize(position: .right, directions: directions)
            case .bottom: return .frameResize(position: .bottom, directions: directions)
            }
        }
        switch edge {
        case .corner: return .crosshair
        case .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        }
    }

    override func resetCursorRects() {
        for (edge, rect) in resizeZones { addCursorRect(rect, cursor: cursor(for: edge)) }
    }

    /// The unsnapped scale after dragging `edge` of a window whose frame was `frame` by `moved`
    /// (screen points, y up). The top-left corner stays put, so dragging down makes it taller.
    static func proposedScale(_ edge: ResizeEdge, frame: NSRect, moved: CGVector) -> CGFloat {
        let sx = (frame.width + moved.dx) / CGFloat(Layout.size.w)
        let sy = (frame.height - moved.dy) / CGFloat(Layout.size.h)
        switch edge {
        case .corner: return max(sx, sy)
        case .right: return sx
        case .bottom: return sy
        }
    }

    /// Follows the mouse in screen coordinates (the view moves under it while the window resizes);
    /// the controller snaps the scale to the nearest step.
    private func resize(to mouse: NSPoint) {
        guard let r = resizing, let c = controller, let w = window else { return }
        var proposed = Self.proposedScale(r.edge, frame: r.frame,
                                          moved: CGVector(dx: mouse.x - r.mouse.x, dy: mouse.y - r.mouse.y))
        // Snapping can put the dragged edge up to half a step ahead of the mouse; don't let that
        // push it off the screen. A window that is already partly off-screen can still shrink.
        if let screen = w.screen?.frame {
            var room = AppDelegate.maxScale
            if r.edge != .bottom { room = min(room, (screen.maxX - r.frame.minX) / CGFloat(Layout.size.w)) }
            if r.edge != .right { room = min(room, (r.frame.maxY - screen.minY) / CGFloat(Layout.size.h)) }
            proposed = min(proposed, max(AppDelegate.snapScale(room, backing: w.backingScaleFactor, rule: .down), scale))
        }
        c.setScale(proposed)
        cursor(for: r.edge).set()
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if resizing != nil {  // the last drag's mouse-up went elsewhere
            resizing = nil
            window?.enableCursorRects()
        }
        if let w = window, let edge = resizeEdge(at: convert(e.locationInWindow, from: nil)) {
            resizing = (edge, NSEvent.mouseLocation, w.frame)
            w.disableCursorRects()  // keep the resize cursor while the mouse is off the edge
            cursor(for: edge).set()
            return
        }
        let p = skinPoint(e)
        guard let c = Layout.hit(p) else {
            window?.performDrag(with: e)
            return
        }
        switch c {
        case .marquee:
            if e.clickCount == 2 { controller?.marqueeDoubleClicked() } else { window?.performDrag(with: e) }
        case .volume, .balance, .position:
            dragging = c
            controller?.slider(c, at: p, phase: .began)
        case .visualizer, .time:
            controller?.clicked(c)
        default:
            held = c
            pressed = c
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if resizing != nil { resize(to: NSEvent.mouseLocation); return }
        let p = skinPoint(e)
        if let d = dragging {
            controller?.slider(d, at: p, phase: .changed)
        } else if let h = held {
            pressed = Layout.rect(h).contains(p) ? h : nil
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if resizing != nil {
            resize(to: NSEvent.mouseLocation)
            resizing = nil
            window?.enableCursorRects()
            window?.invalidateCursorRects(for: self)
            if let w = window, resizeEdge(at: convert(w.mouseLocationOutsideOfEventStream, from: nil)) == nil {
                NSCursor.arrow.set()
            }
            return
        }
        let p = skinPoint(e)
        if let d = dragging {
            dragging = nil
            controller?.slider(d, at: p, phase: .ended)
        } else if let h = held {
            held = nil
            pressed = nil
            if Layout.rect(h).contains(p) { controller?.clicked(h) }
        }
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        controller?.showOptionsMenu(with: e, in: self)
    }

    override func scrollWheel(with e: NSEvent) {
        scrollAccumulator += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.1 : 1)
        let steps = Int(scrollAccumulator)
        guard steps != 0 else { return }
        scrollAccumulator -= CGFloat(steps)
        controller?.nudgeVolume(by: steps * 2)
    }

    // MARK: Keyboard (classic layout: Z X C V B)

    override func keyDown(with e: NSEvent) {
        guard let c = controller, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: e)
            return
        }
        switch e.keyCode {
        case 126: c.nudgeVolume(by: 5); return
        case 125: c.nudgeVolume(by: -5); return
        case 123: c.seek(by: -5); return
        case 124: c.seek(by: 5); return
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "z": c.clicked(.prev)
        case "x": c.clicked(.play)
        case "c": c.clicked(.pause)
        case "v": c.clicked(.stop)
        case "b": c.clicked(.next)
        case "l": c.clicked(.eject)
        case "s": c.clicked(.shuffle)
        case "r": c.clicked(.repeatButton)
        case " ": c.togglePlayPause()
        default: super.keyDown(with: e)
        }
    }

    // MARK: Drag and drop (skins and Spotify links)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let strings = pb.pasteboardItems?.compactMap { $0.string(forType: .string) } ?? []
        return controller?.handleDrop(urls: urls, strings: strings) ?? false
    }

    /// ⌘C copies a link to the current track.
    @objc func copy(_ sender: Any?) { controller?.copyTrackLink() }

    /// ⌘V plays a copied Spotify link.
    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let text = [pb.string(forType: .string), pb.string(forType: .URL)].compactMap { $0 }
        if controller?.handleDrop(urls: [], strings: text) != true {
            controller?.show("NO SPOTIFY LINK ON THE CLIPBOARD", seconds: 2)
        }
    }
}

extension PlayerView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        "Spotify DJ: click to start it, or for different picks while it plays"
    }
}
