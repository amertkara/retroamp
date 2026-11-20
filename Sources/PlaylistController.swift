import AppKit

/// The playlist editor: what it lists (Spotify's queue, your playlists, Liked Songs; or with Music,
/// the playlist it plays from and your playlists), selection and scrolling, docking to the player,
/// and what its buttons and menus do.
@MainActor
final class PlaylistController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    unowned let app: AppDelegate
    let api = SpotifyWebAPI()
    let renderer = PlaylistRenderer()
    private(set) var window: PlaylistWindow!
    private(set) var view: PlaylistView!

    private(set) var geometry = PlaylistGeometry(cols: 0, rows: 4)
    private(set) var isVisible = true
    /// Top-left corner relative to the player's, in skin pixels, so it survives double size.
    private var origin = CGPoint(x: 0, y: CGFloat(Layout.size.h))
    private var dockedBeforeRescale = false

    private(set) var source: PlaylistSource = .queue
    private(set) var entries: [PlaylistEntry] = []
    private(set) var selection = Set<Int>()
    private(set) var offset = 0                 // first visible row
    private var anchor: Int?                    // shift-selection anchor
    private var cursor: Int?                    // keyboard position
    private var complete = true                 // false while more pages are on their way
    private var queueHasCurrent = false         // the queue's first row is the playing item
    private var library: (entries: [PlaylistEntry], offset: Int, complete: Bool)?  // for going back

    private var loadTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var generation = 0
    private var loading = false
    private var suspended = false               // no automatic refreshes after a sign-in problem
    private var lastQueueLoad: TimeInterval = -100
    private var queueRefreshAt: TimeInterval?
    private var lastTrackID = ""
    private var lastMiniTime = ""
    private var musicQueueID: String?           // the Music playlist the queue view shows

    static let maxEntries = 5000

    enum Keys {
        static let visible = "playlistVisible", size = "playlistSize", origin = "playlistOrigin"
        static let source = "playlistSource"
    }

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    private var scale: CGFloat { app.view.scale }
    private var connecting: Bool { connectTask != nil }
    private var music: Bool { app.backend == .music }

    /// After switching between Spotify and Music: start over from the queue.
    func backendChanged() {
        library = nil
        source = .queue
        reload()
        save()
    }

    private func label(_ s: PlaylistSource) -> String { music && s == .queue ? "NOW PLAYING" : s.label }

    // MARK: Window

    func setUp() {
        let d = UserDefaults.standard
        isVisible = d.object(forKey: Keys.visible) as? Bool ?? true
        if let n = Self.pair(d.string(forKey: Keys.size)) {
            geometry = PlaylistGeometry(cols: Self.clamp(Int(n.x)), rows: Self.clamp(Int(n.y)))
        }
        if let n = Self.pair(d.string(forKey: Keys.origin)) { origin = n }
        source = PlaylistSource(storageKey: d.string(forKey: Keys.source))

        let rect = NSRect(x: 0, y: 0, width: CGFloat(geometry.width) * scale, height: CGFloat(geometry.height) * scale)
        window = PlaylistWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Retroamp Playlist Editor"
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenNone]
        window.delegate = self
        view = PlaylistView(frame: rect)
        view.scale = scale
        view.controller = self
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.initialFirstResponder = view
        window.makeFirstResponder(view)
        applyLevel()
        setInfo(music || api.isConnected ? [.info(loadingText)] : PlaylistEntry.notConnected)
        if isVisible { show() }
    }

    static func pair(_ s: String?) -> CGPoint? {
        let n = (s ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 2, n.allSatisfy({ $0.isFinite && abs($0) < 100_000 }) else { return nil }
        return CGPoint(x: n[0], y: n[1])
    }

    static func clamp(_ n: Int) -> Int { max(0, min(40, n)) }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        isVisible = true
        place()
        window.orderFront(nil)
        updateDocking()
        let hasRows = entries.contains { !$0.isInfo }
        if case .queue = source { reload(quiet: hasRows) } else if !hasRows { reload() }
        app.view.needsDisplay = true
        save()
    }

    func hide() {
        isVisible = false
        view.closeMenu()
        if isDocked { app.window.removeChildWindow(window) }
        window.orderOut(nil)
        app.view.needsDisplay = true
        save()
    }

    private var isDocked: Bool { window.parent === app.window }

    private func place() {
        let main = app.window.frame
        let size = NSSize(width: CGFloat(geometry.width) * scale, height: CGFloat(geometry.height) * scale)
        var f = NSRect(origin: NSPoint(x: main.minX + origin.x * scale, y: main.maxY - origin.y * scale - size.height),
                       size: size)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) {
            origin = CGPoint(x: 0, y: CGFloat(Layout.size.h))
            f.origin = NSPoint(x: main.minX, y: main.minY - size.height)
        }
        view.scale = scale
        window.setFrame(f, display: false)
    }

    private func rememberOrigin() {
        let main = app.window.frame, f = window.frame
        origin = CGPoint(x: ((f.minX - main.minX) / scale).rounded(), y: ((main.maxY - f.maxY) / scale).rounded())
    }

    /// Like the classic player, windows whose edges touch move together (a child window follows
    /// its parent). Dragging the playlist on its own undocks it.
    private func updateDocking() {
        let touching = isVisible && Self.touching(window.frame, app.window.frame)
        if touching, !isDocked { app.window.addChildWindow(window, ordered: .above) }
        if !touching, isDocked { app.window.removeChildWindow(window) }
    }

    static func touching(_ a: NSRect, _ b: NSRect) -> Bool {
        let e: CGFloat = 0.5
        let xOverlap = a.minX < b.maxX - e && b.minX < a.maxX - e
        let yOverlap = a.minY < b.maxY - e && b.minY < a.maxY - e
        let stacked = xOverlap && (abs(a.maxY - b.minY) < e || abs(a.minY - b.maxY) < e)
        let sideBySide = yOverlap && (abs(a.maxX - b.minX) < e || abs(a.minX - b.maxX) < e)
        return stacked || sideBySide
    }

    func beginWindowDrag() {
        view.closeMenu()
        if isDocked { app.window.removeChildWindow(window) }
    }

    func endWindowDrag() {
        updateDocking()
        rememberOrigin()
        save()
    }

    /// Snaps to the player's edges and the screen's within 10 points.
    func snapped(_ proposed: NSRect) -> NSRect {
        let d: CGFloat = 10
        let m = app.window.frame
        var f = proposed
        var dx: CGFloat?, dy: CGFloat?
        func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
            if abs(delta) < d, abs(delta) < abs(best ?? .infinity) { best = delta }
        }
        if app.window.isVisible {
            if f.minY < m.maxY + d, m.minY < f.maxY + d {
                for delta in [m.maxX - f.minX, m.minX - f.maxX, m.minX - f.minX, m.maxX - f.maxX] { consider(delta, &dx) }
            }
            if f.minX < m.maxX + d, m.minX < f.maxX + d {
                for delta in [m.minY - f.maxY, m.maxY - f.minY, m.maxY - f.maxY, m.minY - f.minY] { consider(delta, &dy) }
            }
        }
        if let s = (window.screen ?? NSScreen.main)?.visibleFrame {
            for delta in [s.minX - f.minX, s.maxX - f.maxX] { consider(delta, &dx) }
            for delta in [s.minY - f.minY, s.maxY - f.maxY] { consider(delta, &dy) }
        }
        f.origin.x += dx ?? 0
        f.origin.y += dy ?? 0
        return f
    }

    /// Resizes in 25×29 steps, keeping the top-left corner in place.
    func resize(cols: Int, rows: Int) {
        let g = PlaylistGeometry(cols: Self.clamp(cols), rows: Self.clamp(rows))
        guard g != geometry else { return }
        geometry = g
        let f = window.frame
        let size = NSSize(width: CGFloat(g.width) * scale, height: CGFloat(g.height) * scale)
        window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
        clampOffset()
        redraw()
    }

    func endResize() {
        updateDocking()
        save()
    }

    func willChangeScale() {
        guard window != nil else { return }
        dockedBeforeRescale = isDocked
        if isVisible { rememberOrigin() }
        if isDocked { app.window.removeChildWindow(window) }
    }

    func didChangeScale() {
        guard window != nil else { return }
        view.scale = scale
        guard isVisible else { return }
        if dockedBeforeRescale {
            place()
        } else {
            let f = window.frame
            let size = NSSize(width: CGFloat(geometry.width) * scale, height: CGFloat(geometry.height) * scale)
            window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
            rememberOrigin()
        }
        updateDocking()
        redraw()
        save()
    }

    func mainDidMove() {
        guard window != nil, isVisible, !isDocked else { return }
        rememberOrigin()
        updateDocking()
        save()
    }

    func mainWillMiniaturize() {
        guard window != nil, isVisible else { return }
        view.closeMenu()
        if isDocked { app.window.removeChildWindow(window) }
        window.orderOut(nil)
    }

    func mainDidDeminiaturize() {
        guard window != nil, isVisible else { return }
        place()
        window.orderFront(nil)
        updateDocking()
    }

    func applyLevel() { window?.level = app.alwaysOnTop ? .floating : .normal }

    func windowDidBecomeKey(_ notification: Notification) { redraw() }

    func windowDidResignKey(_ notification: Notification) {
        view.closeMenu()
        redraw()
    }

    func save() {
        guard window != nil else { return }
        let d = UserDefaults.standard
        d.set(isVisible, forKey: Keys.visible)
        d.set("\(geometry.cols),\(geometry.rows)", forKey: Keys.size)
        d.set("\(Int(origin.x)),\(Int(origin.y))", forKey: Keys.origin)
        d.set(source.storageKey, forKey: Keys.source)
    }

    // MARK: Drawing

    func redraw() { view?.needsDisplay = true }

    var visibleRowCount: Int { max(0, min(geometry.visibleRows, entries.count - offset)) }

    var handleRect: CGRect {
        let overflow = max(0, entries.count - geometry.visibleRows)
        let frac = overflow > 0 ? Double(min(offset, overflow)) / Double(overflow) : 0
        return CGRect(x: geometry.width - 15, y: 20 + Int((frac * Double(geometry.handleTravel)).rounded()),
                      width: 8, height: PlaylistGeometry.handleHeight)
    }

    func renderState() -> PlaylistRenderState {
        var s = PlaylistRenderState()
        s.geometry = geometry
        s.active = window.isKeyWindow
        s.entries = entries
        s.numbered = entries.contains { !$0.isInfo }
        s.selection = selection
        s.current = currentIndex
        s.offset = offset
        s.pressed = view.pressed
        s.handlePressed = view.draggingScrollbar
        s.openMenu = view.openMenu
        s.menuHover = view.menuHover
        s.runningTime = runningTime
        s.miniTime = miniTime()
        return s
    }

    private var currentIndex: Int? {
        switch source {
        case .queue where !music: return queueHasCurrent && !entries.isEmpty ? 0 : nil
        case .library: return nil
        case .queue, .liked, .playlist:
            let id = app.player.status.trackID
            return id.isEmpty ? nil : entries.firstIndex { $0.uri == id }
        }
    }

    /// "selected/total" track time, with "+" while more tracks are still loading.
    private var runningTime: String {
        guard entries.contains(where: \.isTrack) else { return "" }
        var total = 0.0, selected = 0.0
        for (i, e) in entries.enumerated() where e.isTrack {
            total += e.duration ?? 0
            if selection.contains(i) { selected += e.duration ?? 0 }
        }
        return PlaylistEntry.longTimeString(selected) + "/" + PlaylistEntry.longTimeString(total) + (complete ? "" : "+")
    }

    /// Sign, minutes and seconds; blinks while paused like the main display.
    private func miniTime() -> String {
        let st = app.player.status
        guard st.running, st.state != .stopped, st.duration > 0 else { return "" }
        if st.state == .paused, Int(AppDelegate.now * 2) % 2 == 1 { return "" }
        let pos = app.player.position
        let t = Int(app.timeRemaining ? max(0, st.duration - pos) : pos)
        return (app.timeRemaining ? "-" : " ") + String(format: "%02d%02d", min(99, t / 60), t % 60)
    }

    // MARK: Timers

    /// 30 Hz: follows track changes and keeps the mini time current.
    func tick() {
        guard window != nil, isVisible else { return }
        let id = app.player.status.trackID
        if id != lastTrackID {
            lastTrackID = id
            if case .queue = source { queueRefreshAt = AppDelegate.now + 1 }
            redraw()
        }
        if let at = queueRefreshAt, AppDelegate.now >= at {
            queueRefreshAt = nil
            if case .queue = source, !connecting { reload(quiet: true) }
        }
        let mini = miniTime()
        if mini != lastMiniTime {
            lastMiniTime = mini
            redraw()
        }
    }

    /// Once a second: refreshes the queue every 15 seconds while it's on screen.
    func poll() {
        guard window != nil, isVisible, case .queue = source, !music, !loading, !suspended, !connecting, api.isConnected,
              AppDelegate.now - lastQueueLoad > 15 else { return }
        reload(quiet: true)
    }

    // MARK: Loading

    private var loadingText: String {
        switch source {
        case .queue: return music ? "Loading what Music is playing\u{2026}" : "Loading Spotify's queue\u{2026}"
        case .library: return "Loading your playlists\u{2026}"
        case .liked: return "Loading Liked Songs\u{2026}"
        case .playlist(_, let name, _): return "Loading \(name)\u{2026}"
        }
    }

    func refresh() {
        suspended = false
        library = nil
        reload(quiet: entries.contains { !$0.isInfo })
    }

    /// Loads the current source. `quiet` keeps the rows on screen until the new ones arrive.
    private func reload(quiet: Bool = false) {
        loadTask?.cancel()
        generation += 1
        loading = false
        guard !connecting else { return }
        guard music || api.isConnected else {
            setInfo(PlaylistEntry.notConnected)
            return
        }
        if !quiet { setInfo([.info(loadingText)]) }
        let gen = generation, src = source
        loading = true
        loadTask = Task { [weak self] in await self?.load(src, gen, quiet: quiet) }
    }

    private func load(_ src: PlaylistSource, _ gen: Int, quiet: Bool) async {
        defer { if gen == generation { loading = false } }
        do {
            if music {
                try await loadMusic(src, gen)
                return
            }
            switch src {
            case .queue:
                lastQueueLoad = AppDelegate.now
                let q = try await api.queue()
                guard gen == generation else { return }
                let rows = (q.current.map { [$0] } ?? []) + q.upNext
                if rows.isEmpty {
                    setInfo([.info("Nothing is playing in Spotify."), .info(""),
                             .info("Double-click here to pick one of your playlists.", .showLibrary),
                             .info("Double-click here to start Spotify DJ.", .playDJ)])
                } else {
                    setEntries(rows, complete: true)
                    queueHasCurrent = q.current != nil
                }
            case .library:
                var page = try await api.playlists(next: nil)
                guard gen == generation else { return }
                setEntries([PlaylistEntry(kind: .liked, title: "Liked Songs"), .dj] + page.entries, complete: page.next == nil)
                if let n = try? await api.likedCount(), gen == generation, entries.first?.kind == .liked {
                    entries[0].count = n
                    redraw()
                }
                while let next = page.next, entries.count < Self.maxEntries {
                    page = try await api.playlists(next: next)
                    guard gen == generation else { return }
                    append(page.entries, complete: page.next == nil)
                }
            case .liked:
                _ = try await api.me()  // for the Liked Songs context URI
                try await loadTracks(gen) { try await self.api.likedTracks(next: $0) }
            case .playlist(let id, _, _):
                try await loadTracks(gen) { try await self.api.playlistItems(id: id, next: $0) }
            }
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            failed(error, src, quiet: quiet)
        }
    }

    private func loadMusic(_ src: PlaylistSource, _ gen: Int) async throws {
        switch src {
        case .library:
            let rows = try await MusicLibrary.playlists()
            guard gen == generation else { return }
            if rows.isEmpty { setInfo([.info("You have no playlists in Music.")]) } else { setEntries(rows, complete: true) }
        case .queue, .playlist:
            var id: String?
            if case .playlist(let pid, _, _) = src { id = pid }
            let list: (id: String, name: String, tracks: [PlaylistEntry])
            do {
                list = try await MusicLibrary.tracks(playlist: id, limit: Self.maxEntries)
            } catch let e as MusicLibrary.ScriptError where e.code == -1728 && id == nil {
                guard gen == generation else { return }
                setInfo([.info("Music isn't playing from one of your playlists."), .info(""),
                         .info("Double-click here to pick one.", .showLibrary)])
                return
            }
            guard gen == generation else { return }
            if id == nil { musicQueueID = list.id }
            if list.tracks.isEmpty { setInfo([.info("Nothing here yet.")]) } else { setEntries(list.tracks, complete: true) }
        case .liked:
            setInfo([.info("Liked Songs is a Spotify list."), .info(""),
                     .info("Double-click here to see your playlists.", .showLibrary)])
        }
    }

    private func loadTracks(_ gen: Int, _ fetch: (String?) async throws -> SpotifyWebAPI.Page) async throws {
        var page = try await fetch(nil)
        guard gen == generation else { return }
        guard !page.entries.isEmpty else {
            setInfo([.info("Nothing here yet.")])
            return
        }
        setEntries(page.entries, complete: page.next == nil)
        while let next = page.next, entries.count < Self.maxEntries {
            page = try await fetch(next)
            guard gen == generation else { return }
            append(page.entries, complete: page.next == nil)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func failed(_ error: Error, _ src: PlaylistSource, quiet: Bool) {
        let text = message(for: error)
        let apiError = error as? WebAPIError
        if case .playlist(_, let name, let uri) = src, case .forbidden(let why)? = apiError {
            setInfo(notOwnedRows(name, uri) + (why.isEmpty ? [] : [.info("")] + wrap("(Spotify: \(why))")))
            return
        }
        if case .queue = src, case .http(404, _)? = apiError {
            setInfo([.info("Spotify isn't playing on any device."), .info(""),
                     .info("Double-click here to pick one of your playlists.", .showLibrary),
                     .info("Double-click here to start Spotify DJ.", .playDJ)])
            return
        }
        switch apiError {
        case .signIn?, .notConnected?:
            suspended = true
            setInfo(wrap(text) + [.info(""), .info("Double-click here to try again.", .retry),
                                  .info("Double-click here to connect again\u{2026}", .connect)])
        default:
            if quiet, entries.contains(where: { !$0.isInfo }) {
                app.show("PLAYLIST: \(text.uppercased())", seconds: 4)
                return
            }
            setInfo(wrap("Couldn't load \(src.label.lowercased()). \(text)")
                    + [.info(""), .info("Double-click here to try again.", .retry)])
        }
    }

    private func notOwnedRows(_ name: String, _ uri: String) -> [PlaylistEntry] {
        [.info(name), .info("")]
            + wrap("Spotify only lets apps list the tracks of playlists you own or collaborate on.")
            + [.info(""), .info("Double-click here to play this playlist.", .playContext(uri)),
               .info("Double-click here to go back.", .showLibrary)]
    }

    /// Splits a message into rows that fit the list (the list font averages about 5 px a character).
    private func wrap(_ text: String) -> [PlaylistEntry] {
        let width = max(20, (geometry.width - 40) / 5)
        var rows: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty { line = String(word) } else if line.count + 1 + word.count <= width { line += " " + word } else {
                rows.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { rows.append(line) }
        return rows.map { .info($0) }
    }

    /// Replaces the rows, keeping selected items selected (matched by URI) when the list refreshes.
    private func setEntries(_ new: [PlaylistEntry], complete: Bool) {
        if new != entries {
            let keep = Set(selection.compactMap { entries.indices.contains($0) ? entries[$0].uri : nil })
            entries = new
            selection = keep.isEmpty ? [] : Set(new.indices.filter { new[$0].uri.map(keep.contains) ?? false })
            if let c = cursor, c >= new.count { cursor = nil }
            if let a = anchor, a >= new.count { anchor = nil }
        }
        self.complete = complete
        clampOffset()
        redraw()
    }

    private func append(_ more: [PlaylistEntry], complete: Bool) {
        entries += more
        self.complete = complete
        redraw()
    }

    private func setInfo(_ rows: [PlaylistEntry]) {
        entries = rows
        selection = []
        anchor = nil
        cursor = nil
        offset = 0
        complete = true
        queueHasCurrent = false
        redraw()
    }

    // MARK: Navigation

    func open(_ target: PlaylistSource) {
        view.closeMenu()
        let goingBack: Bool
        switch (source, target) {
        case (.playlist, .library), (.liked, .library): goingBack = true
        default: goingBack = false
        }
        if goingBack, let saved = library, saved.complete {
            loadTask?.cancel()
            generation += 1
            loading = false
            source = .library
            setInfo([])
            entries = saved.entries
            offset = saved.offset
            clampOffset()
            app.show("PLAYLIST: \(label(source))", seconds: 2)
            redraw()
            save()
            return
        }
        switch target {
        case .playlist, .liked:
            if case .library = source { library = (entries, offset, complete) }
        case .queue, .library:
            library = nil
        }
        source = target
        app.show("PLAYLIST: \(label(target))", seconds: 2)
        reload()
        save()
    }

    /// Backspace: from a playlist to Your Playlists, from there to the queue.
    func back() {
        switch source {
        case .playlist, .liked: open(.library)
        case .library: open(.queue)
        case .queue: break
        }
    }

    // MARK: Selection and scrolling

    func click(_ index: Int, extend: Bool, toggle: Bool) {
        guard entries.indices.contains(index) else { return }
        if extend, let a = anchor {
            selection = Set(min(a, index)...max(a, index))
        } else if toggle {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else {
            selection = [index]
            anchor = index
        }
        cursor = index
        redraw()
    }

    func rightClicked(_ index: Int) {
        guard entries.indices.contains(index), !selection.contains(index) else { return }
        selection = [index]
        anchor = index
        cursor = index
        redraw()
    }

    func selectNone() { selection = []; redraw() }
    func selectAll() { selection = Set(entries.indices); redraw() }
    func invertSelection() { selection = Set(entries.indices).subtracting(selection); redraw() }

    private func selectedEntries() -> [PlaylistEntry] {
        selection.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    func scroll(by rows: Int) {
        let old = offset
        offset += rows
        clampOffset()
        if offset != old { redraw() }
    }

    func scrollHandle(toTop y: CGFloat) {
        let overflow = max(0, entries.count - geometry.visibleRows)
        guard overflow > 0, geometry.handleTravel > 0 else { return }
        let frac = max(0, min(1, (Double(y) - 20) / Double(geometry.handleTravel)))
        let new = Int((frac * Double(overflow)).rounded())
        if new != offset {
            offset = new
            redraw()
        }
    }

    private func clampOffset() { offset = max(0, min(offset, max(0, entries.count - geometry.visibleRows))) }

    private func moveCursor(to target: Int, extend: Bool) {
        guard !entries.isEmpty else { return }
        let i = max(0, min(entries.count - 1, target))
        if extend, let a = anchor { selection = Set(min(a, i)...max(a, i)) } else {
            selection = [i]
            anchor = i
        }
        cursor = i
        if i < offset { offset = i } else if i >= offset + geometry.visibleRows { offset = i - geometry.visibleRows + 1 }
        clampOffset()
        redraw()
    }

    /// Playlist keys; anything else falls through to the player's (Z X C V B, arrows for seeking…).
    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "r" {
            refresh()
            return true
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        let shift = mods.contains(.shift)
        let page = max(1, geometry.visibleRows - 1)
        let at = cursor ?? selection.min() ?? -1
        switch e.keyCode {
        case 126: moveCursor(to: max(0, at - 1), extend: shift)
        case 125: moveCursor(to: at + 1, extend: shift)
        case 116: moveCursor(to: max(0, at) - page, extend: shift)
        case 121: moveCursor(to: max(0, at) + page, extend: shift)
        case 115: moveCursor(to: 0, extend: shift)
        case 119: moveCursor(to: entries.count - 1, extend: shift)
        case 36, 76: if let i = cursor ?? selection.min() { activate(i) }
        case 51, 53: back()  // Backspace or Esc: up one level
        default: return false
        }
        return true
    }

    // MARK: Playing

    /// Double-click or Return.
    func activate(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let e = entries[index]
        switch e.kind {
        case .info(let action): perform(action)
        case .liked: open(.liked)
        case .dj: app.playDJ()
        case .playlist(let owned):
            guard let id = e.id, let uri = e.uri else { return }
            let target = PlaylistSource.playlist(id: id, name: e.title, uri: uri)
            if owned {
                open(target)
            } else {
                library = (entries, offset, complete)
                loadTask?.cancel()
                generation += 1
                loading = false
                source = target
                setInfo(notOwnedRows(e.title, uri))
                app.show("PLAYLIST: \(target.label)", seconds: 2)
            }
        case .local:
            app.show("LOCAL FILES CAN'T BE STARTED FROM HERE", seconds: 2.5)
        case .track:
            guard let uri = e.uri else { return }
            play(e, at: index, uri: uri)
        }
    }

    private func play(_ e: PlaylistEntry, at index: Int, uri: String) {
        if music {
            var list = musicQueueID
            if case .playlist(let id, _, _) = source { list = id }
            guard let list, app.music.playMusic(playlist: list, track: uri) else { return }
            app.show("PLAYING \(e.title.uppercased())", seconds: 2)
            return
        }
        let spotify = app.spotify
        let what: Playback.What
        switch source {
        case .queue where queueHasCurrent:
            if index == 0 {
                spotify.seek(to: 0)  // classic: double-clicking the current track restarts it
                if spotify.status.state != .playing { spotify.play() }
            } else {
                spotify.skip(times: index)
                app.show("SKIPPING AHEAD \(index) TRACK\(index == 1 ? "" : "S")...", seconds: 2)
                queueRefreshAt = AppDelegate.now + 0.3 * Double(index) + 1.2
            }
            return
        case .playlist(_, _, let context):
            what = .track(uri, context: context, following: tracks(from: index))
        case .liked:
            if let me = api.user {
                what = .track(uri, context: "spotify:user:\(me.id):collection", following: tracks(from: index))
            } else {
                what = .item(uri)
            }
        case .queue, .library:
            what = .item(uri)
        }
        app.playback.start(what)
        app.show("PLAYING \(e.title.uppercased())", seconds: 2)
    }

    /// The playable tracks from `index` on, for when Spotify won't start the list as a context.
    private func tracks(from index: Int) -> [String] {
        guard entries.indices.contains(index) else { return [] }
        return Array(entries[index...].lazy.filter { $0.kind == .track }.compactMap(\.uri).filter(SpotifyLink.isTrackLike).prefix(50))
    }

    /// After DJ starts: refreshes the queue if that's the list on show, without leaving the one you're in.
    func refreshQueueIfShown() {
        guard case .queue = source, window != nil, isVisible, api.isConnected, !connecting else { return }
        queueRefreshAt = AppDelegate.now + 1
    }

    private func perform(_ action: InfoAction) {
        switch action {
        case .none: break
        case .connect: connect()
        case .cancelConnect: cancelConnect()
        case .retry: refresh()
        case .playContext(let uri):
            app.playback.start(.item(uri))
            app.show("PLAYING PLAYLIST", seconds: 2)
        case .playDJ: app.playDJ()
        case .showLibrary: open(.library)
        case .showQueue: open(.queue)
        }
    }

    // MARK: Buttons and menus

    func buttonClicked(_ h: PlaylistHit) {
        switch h {
        case .close: hide()
        case .shade: app.show("WINDOWSHADE MODE: COMING SOON")
        case .action(let i):
            let controls: [Control] = [.prev, .play, .pause, .stop, .next, .eject]
            if controls.indices.contains(i) { app.clicked(controls[i]) }
        case .miniTime: app.toggleTimeRemaining()
        case .scrollUp: scroll(by: -4)
        case .scrollDown: scroll(by: 4)
        default: break
        }
    }

    func menuHovered(_ m: PlaylistMenu, _ i: Int) {
        guard m.items.indices.contains(i) else { return }
        app.show(Self.hint(m.items[i]), seconds: 2)
    }

    static func hint(_ item: PlaylistMenuItem) -> String {
        switch item {
        case .addURL: return "ADD URL: QUEUE A SPOTIFY LINK"
        case .addDir: return "ADD DIR: BROWSE YOUR PLAYLISTS"
        case .addFile: return "ADD FILE: QUEUE THE SELECTED TRACKS"
        case .removeMisc, .removeAll, .crop, .removeSelected: return "REMOVE: SPOTIFY'S QUEUE CAN'T BE EDITED BY APPS"
        case .invertSelection: return "SEL INV: INVERT THE SELECTION"
        case .selectZero: return "SEL ZERO: SELECT NONE"
        case .selectAll: return "SEL ALL: SELECT EVERYTHING"
        case .sortList: return "SORT LIST: NOT AVAILABLE FOR SPOTIFY LISTS"
        case .fileInfo: return "FILE INFO: SHOW IN SPOTIFY"
        case .miscOptions: return "MISC OPTS: PLAYLIST OPTIONS"
        case .newList: return "NEW LIST: SHOW SPOTIFY'S QUEUE"
        case .saveList: return "SAVE LIST: COPY THE LINKS"
        case .loadList: return "LOAD LIST: YOUR PLAYLISTS"
        }
    }

    func menuChosen(_ m: PlaylistMenu, _ i: Int) {
        guard m.items.indices.contains(i) else { return }
        let spotifyOnly: Set<PlaylistMenuItem> = [.addURL, .addFile, .removeMisc, .removeAll, .crop, .removeSelected,
                                                  .sortList, .fileInfo, .saveList]
        if music, spotifyOnly.contains(m.items[i]) {
            app.show("NOT AVAILABLE FOR APPLE MUSIC", seconds: 2)
            return
        }
        switch m.items[i] {
        case .addURL: promptAddURL()
        case .addDir, .loadList: open(.library)
        case .addFile: queueSelection()
        case .removeMisc, .removeAll, .crop, .removeSelected:
            app.show("SPOTIFY DOESN'T LET APPS REMOVE ITEMS FROM THE QUEUE", seconds: 3)
        case .invertSelection: invertSelection()
        case .selectZero: selectNone()
        case .selectAll: selectAll()
        case .sortList: app.show("SORTING ISN'T AVAILABLE FOR SPOTIFY LISTS", seconds: 2.5)
        case .fileInfo: showInSpotify()
        case .miscOptions:
            let r = geometry.menuButton(.misc)
            contextMenu().popUp(positioning: nil, at: NSPoint(x: r.minX * scale, y: view.bounds.height - r.minY * scale),
                                in: view)
        case .newList: open(.queue)
        case .saveList: copyLinks()
        }
    }

    func queueSelection() {
        let uris = selectedEntries().filter { $0.kind == .track }.compactMap(\.uri)
        guard !uris.isEmpty else {
            app.show("SELECT SOME TRACKS FIRST", seconds: 2)
            return
        }
        addToQueue(uris)
    }

    private func addToQueue(_ uris: [String]) {
        guard !music else {
            app.show("MUSIC DOESN'T LET APPS ADD TO UP NEXT", seconds: 2.5)
            return
        }
        guard api.isConnected else {
            connect()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var added = 0
            for uri in uris.prefix(50) {
                do {
                    try await self.api.addToQueue(uri)
                    added += 1
                } catch {
                    self.app.show("COULDN'T QUEUE IT: \(self.message(for: error).uppercased())", seconds: 5)
                    break
                }
            }
            guard added > 0 else { return }
            self.app.show(added == 1 ? "ADDED TO THE QUEUE" : "ADDED \(added) TRACKS TO THE QUEUE", seconds: 2)
            if case .queue = self.source { self.queueRefreshAt = AppDelegate.now + 0.5 }
        }
    }

    func promptAddURL() {
        let alert = NSAlert()
        alert.messageText = "Add to Spotify's queue"
        alert.informativeText = "Paste a link to a track or podcast episode (open.spotify.com/… or spotify:…)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://open.spotify.com/track/…"
        if let clip = NSPasteboard.general.string(forType: .string), SpotifyLink.uri(from: clip) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Add to Queue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        queueLink(field.stringValue)
    }

    /// ⌘V in the playlist queues a copied link.
    func pasteToQueue() {
        let pb = NSPasteboard.general
        let texts = [pb.string(forType: .string), pb.string(forType: .URL)].compactMap { $0 }
        guard let text = texts.first(where: { SpotifyLink.uri(from: $0) != nil }) else {
            app.show("NO SPOTIFY LINK ON THE CLIPBOARD", seconds: 2)
            return
        }
        queueLink(text)
    }

    private func queueLink(_ text: String) {
        guard let uri = SpotifyLink.uri(from: text) else {
            app.show("THAT IS NOT A SPOTIFY LINK", seconds: 3)
            return
        }
        guard uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:") else {
            app.show("ONLY TRACKS AND EPISODES CAN BE QUEUED", seconds: 3)
            return
        }
        addToQueue([uri])
    }

    /// ⌘C and SAVE LIST: links to the selection, or to everything when nothing is selected.
    func copyLinks() {
        let chosen = selection.isEmpty ? entries : selectedEntries()
        let links = chosen.compactMap { $0.uri.flatMap(SpotifyLink.webURL(for:)) }
        guard !links.isEmpty else {
            app.show("NOTHING TO COPY", seconds: 2)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        app.show(links.count == 1 ? "LINK COPIED" : "\(links.count) LINKS COPIED", seconds: 2)
    }

    func showInSpotify() {
        if music {
            app.showSpotify()  // brings Music forward
            return
        }
        let e = selectedEntries().first(where: { $0.uri != nil }) ?? currentIndex.map { entries[$0] }
        guard let uri = e?.uri, let safe = SpotifyLink.sanitized(uri), let url = URL(string: safe) else {
            app.show("SELECT SOMETHING FIRST", seconds: 2)
            return
        }
        app.playback.focus.disarm()  // this one is meant to bring Spotify up
        NSWorkspace.shared.open(url)
    }

    // MARK: Context menu

    func contextMenu() -> NSMenu {
        let m = NSMenu(title: "Playlist")
        func add(_ title: String, _ action: Selector, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            m.addItem(item)
        }
        if music {
            add("Now Playing", #selector(menuSource(_:)), tag: 0)
            add("Your Playlists", #selector(menuSource(_:)), tag: 1)
            m.addItem(.separator())
            add("Play", #selector(menuPlay))
            add("Show Music", #selector(menuShowInSpotify))
            m.addItem(.separator())
            add("Refresh", #selector(menuRefresh))
            add("Close Playlist Editor", #selector(menuClose))
            return m
        }
        add("Queue", #selector(menuSource(_:)), tag: 0)
        add("Your Playlists", #selector(menuSource(_:)), tag: 1)
        add("Liked Songs", #selector(menuSource(_:)), tag: 2)
        m.addItem(.separator())
        add("Play", #selector(menuPlay))
        add("Play Spotify DJ", #selector(menuPlayDJ))
        add("Add to Queue", #selector(menuAddToQueue))
        add("Add Spotify Link to Queue…", #selector(menuAddLink))
        add("Copy Link", #selector(menuCopyLinks))
        add("Show in Spotify", #selector(menuShowInSpotify))
        m.addItem(.separator())
        add("Refresh", #selector(menuRefresh))
        m.addItem(.separator())
        add(connectionMenuTitle, #selector(menuToggleConnection))
        add("Close Playlist Editor", #selector(menuClose))
        return m
    }

    var connectionMenuTitle: String {
        if connecting { return "Cancel Connecting to Spotify" }
        if api.isConnected { return "Disconnect Spotify" + (api.user.map { " (\($0.name))" } ?? "") }
        return "Connect Spotify…"
    }

    @objc private func menuSource(_ item: NSMenuItem) {
        let sources: [PlaylistSource] = [.queue, .library, .liked]
        if sources.indices.contains(item.tag) { open(sources[item.tag]) }
    }

    @objc private func menuPlay() { if let i = selection.min() { activate(i) } }
    @objc private func menuPlayDJ() { app.playDJ() }
    @objc private func menuAddToQueue() { queueSelection() }
    @objc private func menuAddLink() { promptAddURL() }
    @objc private func menuCopyLinks() { copyLinks() }
    @objc private func menuShowInSpotify() { showInSpotify() }
    @objc private func menuRefresh() { refresh() }
    @objc private func menuToggleConnection() { toggleConnection() }
    @objc private func menuClose() { hide() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuSource(_:)):
            let current: Int
            switch source {
            case .queue: current = 0
            case .library: current = 1
            case .liked: current = 2
            case .playlist: current = -1
            }
            item.state = item.tag == current ? .on : .off
        case #selector(menuPlay): return !selection.isEmpty
        case #selector(menuAddToQueue): return selectedEntries().contains { $0.kind == .track && $0.uri != nil }
        case #selector(menuShowInSpotify): return music || selectedEntries().contains { $0.uri != nil }
        case #selector(menuCopyLinks): return entries.contains { $0.uri.flatMap(SpotifyLink.webURL(for:)) != nil }
        default: break
        }
        return true
    }

    // MARK: Connecting

    func toggleConnection() {
        if connecting { cancelConnect() } else if api.isConnected { disconnect() } else { connect() }
    }

    func connect() {
        guard !connecting else {
            if !isVisible { show() }
            return
        }
        guard let id = askForClientID() else { return }
        if !isVisible { show() }
        loadTask?.cancel()
        generation += 1
        loading = false
        setInfo([.info("Waiting for you to sign in to Spotify in your browser\u{2026}"), .info(""),
                 .info("Double-click here to cancel.", .cancelConnect)])
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.connect(clientID: id)
                self.connectTask = nil
                self.suspended = false
                self.library = nil
                self.app.show("SPOTIFY: CONNECTED AS \((self.api.user?.name ?? "you").uppercased())", seconds: 3)
                self.reload()
            } catch {
                self.connectTask = nil
                if case WebAPIError.cancelled = error {
                    self.setInfo(PlaylistEntry.notConnected)
                } else {
                    self.setInfo(self.wrap("Couldn't connect to Spotify. \(self.message(for: error))")
                                 + [.info(""), .info("Double-click here to try again\u{2026}", .connect)])
                }
            }
            NSApp.activate()  // back from the browser
        }
    }

    func cancelConnect() { api.cancelConnect() }

    func disconnect() {
        api.disconnect()
        loadTask?.cancel()
        generation += 1
        loading = false
        library = nil
        setInfo(PlaylistEntry.notConnected)
        app.show("SPOTIFY: DISCONNECTED", seconds: 2)
    }

    /// Explains the one-time setup and asks for the Client ID of the user's Spotify developer app.
    private func askForClientID() -> String? {
        var typed = api.clientID ?? ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Connect Retroamp to Spotify"
            alert.informativeText = """
            To show your queue and playlists, Retroamp uses Spotify's Web API. Spotify requires a Client ID from your own developer app (free, about a minute):

            1. Click Open Dashboard, log in and create an app (any name and description).
            2. Add the Redirect URI below. Open Dashboard also copies it for you.
            3. Select Web API, save, and paste the app's Client ID here.

            The developer app's owner needs Spotify Premium. Your sign-in is kept in the macOS Keychain.
            """
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 384, height: 60))
            let redirectLabel = NSTextField(labelWithString: "Redirect URI:")
            redirectLabel.frame = NSRect(x: 0, y: 36, width: 88, height: 18)
            redirectLabel.alignment = .right
            let redirect = NSTextField(string: SpotifyWebAPI.redirectURI)
            redirect.isEditable = false
            redirect.isSelectable = true
            redirect.frame = NSRect(x: 94, y: 33, width: 290, height: 24)
            let idLabel = NSTextField(labelWithString: "Client ID:")
            idLabel.frame = NSRect(x: 0, y: 5, width: 88, height: 18)
            idLabel.alignment = .right
            let idField = NSTextField(string: typed)
            idField.placeholderString = "32 characters from your app's page"
            idField.frame = NSRect(x: 94, y: 2, width: 290, height: 24)
            for v in [redirectLabel, redirect, idLabel, idField] { box.addSubview(v) }
            alert.accessoryView = box
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Open Dashboard")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = idField
            NSApp.activate()
            let response = alert.runModal()
            typed = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch response {
            case .alertFirstButtonReturn:
                if SpotifyWebAPI.isValidClientID(typed) { return typed }
                let bad = NSAlert()
                bad.messageText = "That isn't a Client ID"
                bad.informativeText = "A Client ID has 32 characters (0–9 and a–f). It's shown on your app's page in the Spotify Developer Dashboard."
                bad.runModal()
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SpotifyWebAPI.redirectURI, forType: .string)
                NSWorkspace.shared.open(SpotifyWebAPI.dashboardURL)
            default:
                return nil
            }
        }
    }
}
