import AppKit

/// Owns the window, timers and state, and wires Spotify, the audio tap and the renderer together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let spotify = SpotifyBridge()
    let analyzer = Analyzer()
    private(set) lazy var tap = AudioTap(analyzer: analyzer)
    /// Starts tracks, playlists and DJ without bringing Spotify's window forward.
    private(set) lazy var playback = Playback(spotify: spotify)
    let renderer = MainRenderer()
    var skin = Skin.builtIn
    var window: PlayerWindow!
    var view: PlayerView!
    var playlist: PlaylistController!

    // Preferences
    var alwaysOnTop = false
    /// Points per skin pixel. 1 is the original 275×116; dragging the window's edge goes up to
    /// `maxScale`, in steps that keep every skin pixel a whole number of screen pixels.
    var scale: CGFloat = 1
    static let maxScale: CGFloat = 3
    var visMode: VisMode = .bars
    var timeRemaining = false
    /// "classic" (the downloaded Winamp base skin, the default), "builtin" or "file".
    var skinChoice = SkinChoice.classic

    // Transient UI state
    var balance = 0
    var volumeOverride: Int?        // thumb position while dragging the volume slider
    var pendingVolume: Int?         // scroll-wheel/arrow volume waiting to be sent
    var positionOverride: Double?   // 0…1 while dragging the position bar
    var lastVolumeSent: TimeInterval = 0
    var spotifyAppRunning = false
    var spotifyInstalled = true
    private var marqueeOffset = 0
    private var marqueeStepAt: TimeInterval = 0
    private var lastMarqueeText = ""
    private var message: String?
    private var messageUntil: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var timers: [Timer] = []
    private var playingSince: TimeInterval?
    private var tapHintShown = false
    private var tapFailHintShown = false
    private var skinDownload: Task<Void, Never>?

    enum Keys {
        static let skinPath = "skinPath", alwaysOnTop = "alwaysOnTop", scale = "windowScale"
        static let legacyDoubleSize = "doubleSize"  // v0.1–0.2 opened at 2× by default
        static let visMode = "visMode", timeRemaining = "timeRemaining", windowTopLeft = "windowTopLeft"
        static let skinChoice = "skinChoice"
    }

    enum SkinChoice: String { case classic, builtin, file }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadPreferences()
        buildMainMenu()
        createWindow()
        playlist = PlaylistController(app: self)
        playlist.setUp()

        spotify.onMessage = { [weak self] text in self?.show(text, seconds: 5) }
        playback.api = playlist.api
        playback.onMessage = { [weak self] text, seconds in self?.show(text, seconds: seconds) }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(spotifyChanged(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil,
            suspensionBehavior: .deliverImmediately)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        startTimers()
        pollTick()
        if skinChoice == .classic, skin.isBuiltIn { downloadClassicSkin(announce: false) }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        savePreferences()
        playlist?.save()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { loadSkin(from: url) }
    }

    private func createWindow() {
        scale = Self.snapScale(scale, backing: NSScreen.main?.backingScaleFactor ?? 2)
        let s = scale
        let rect = NSRect(x: 0, y: 0, width: CGFloat(Layout.size.w) * s, height: CGFloat(Layout.size.h) * s)
        window = PlayerWindow(contentRect: rect, styleMask: [.borderless, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Retroamp"
        window.isReleasedWhenClosed = false
        window.hasShadow = false  // the classic windows have none
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenNone]
        window.delegate = self

        view = PlayerView(frame: rect)
        view.scale = s
        view.controller = self
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        if let saved = UserDefaults.standard.string(forKey: Keys.windowTopLeft) {
            window.setFrameTopLeftPoint(NSPointFromString(saved))
        } else {
            window.center()
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        applyWindowLevel()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func startTimers() {
        let ui = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        let poll = Timer(timeInterval: 1.0, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        for t in [ui, poll] { RunLoop.main.add(t, forMode: .common) }
        timers = [ui, poll]
    }

    // MARK: Timers and notifications

    @objc private func tick() {
        let now = Self.now
        let dt = lastTick == 0 ? 1.0 / 30 : min(0.2, now - lastTick)
        lastTick = now
        analyzer.update(dt: dt)
        if now - marqueeStepAt >= 0.22 {
            marqueeStepAt = now
            marqueeOffset += 1
        }
        if window.occlusionState.contains(.visible) { view.needsDisplay = true }
        playlist?.tick()
    }

    @objc func pollTick() {
        spotifyAppRunning = spotify.isRunning
        spotifyInstalled = spotify.isInstalled
        spotify.poll()
        tap.maintain(spotifyRunning: spotifyAppRunning)
        checkVisualizerPermission()
        playlist?.poll()
    }

    @objc private func spotifyChanged(_ n: Notification) {
        if let info = n.userInfo { spotify.apply(notification: info) }
        spotify.refreshSoon()
    }

    @objc private func appsChanged(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == SpotifyBridge.bundleID else { return }
        perform(#selector(pollTick), with: nil, afterDelay: 0.5)
    }

    /// The tap delivers silence when System Audio Recording is denied; explain once. If capture
    /// keeps failing to start, show Core Audio's error once.
    private func checkVisualizerPermission() {
        let now = Self.now
        if !tapFailHintShown, tap.failedStarts >= 3, case .failed(let err) = tap.status {
            tapFailHintShown = true
            let code = AudioTap.fourCC(err).map { "'\($0)'" } ?? String(err)
            show("THE VISUALIZER CAN'T START: CORE AUDIO ERROR \(code)", seconds: 12)
        }
        // Spotify must be playing here, not on another Connect device, and the tap running.
        guard tap.status == .running, tap.spotifyOutputActive, spotify.status.state == .playing else {
            playingSince = nil
            return
        }
        let since = playingSince ?? now
        playingSince = since
        if !tapHintShown, now - since > 6, analyzer.secondsSinceSignal > 5 {
            tapHintShown = true
            show("NO AUDIO FOR THE VISUALIZER? ALLOW RETROAMP IN SYSTEM SETTINGS > PRIVACY & SECURITY > SCREEN & SYSTEM AUDIO RECORDING", seconds: 14)
        }
    }

    // MARK: Rendering

    func show(_ text: String, seconds: Double = 1.5) {
        message = text
        messageUntil = Self.now + seconds
    }

    private func marqueeText(now: TimeInterval) -> String {
        if let m = message, now < messageUntil { return m }
        message = nil
        let st = spotify.status
        if !st.running {
            if spotifyAppRunning {
                return spotify.automationDenied ? "RETROAMP NEEDS PERMISSION TO CONTROL SPOTIFY" : "CONNECTING TO SPOTIFY..."
            }
            return spotifyInstalled ? "SPOTIFY IS NOT RUNNING - PRESS PLAY TO START IT" : "SPOTIFY IS NOT INSTALLED"
        }
        guard !st.name.isEmpty else { return "SPOTIFY - NOTHING PLAYING" }
        let artist = st.artist.isEmpty ? "" : "\(st.artist) - "
        let length = st.duration > 0 ? " (\(Self.format(st.duration)))" : ""
        return "\(artist)\(st.name)\(length)"
    }

    static func format(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    func renderFrame() -> CGImage? {
        let now = Self.now
        let st = spotify.status
        var s = RenderState()
        s.playback = st.running ? st.state : .stopped
        s.elapsed = spotify.position
        s.duration = st.duration
        s.volume = volumeOverride ?? pendingVolume ?? st.volume
        s.balance = balance
        s.shuffle = st.shuffle
        s.repeating = st.repeating
        if s.playback != .stopped, tap.sampleRate > 0 { s.kHz = Int(tap.sampleRate / 1000) }
        s.windowActive = window.isKeyWindow
        s.alwaysOnTop = alwaysOnTop
        s.doubleSize = scale == 2
        s.visMode = visMode
        s.timeRemaining = timeRemaining
        s.playlistOpen = playlist?.isVisible ?? false
        s.timeVisible = s.playback != .paused || Int(now * 2) % 2 == 0
        s.pressed = view.pressed
        s.dragging = view.dragging
        s.positionOverride = positionOverride
        s.bars = analyzer.bars
        s.peaks = analyzer.peaks
        s.osc = analyzer.osc

        let text = marqueeText(now: now)
        if text != lastMarqueeText {
            lastMarqueeText = text
            marqueeOffset = 0
            marqueeStepAt = now + 1  // hold still for a moment before scrolling
        }
        s.marquee = text
        s.marqueeOffset = marqueeOffset
        return renderer.render(skin: skin, state: s)
    }

    // MARK: Window

    func applyWindowLevel() {
        window?.level = alwaysOnTop ? .floating : .normal
        playlist?.applyLevel()
    }

    /// Resizes the player (and the playlist with it) around its top-left corner.
    func setScale(_ proposed: CGFloat) {
        let s = min(Self.snapScale(proposed, backing: window.backingScaleFactor), largestScale)
        guard s != scale else { return }
        scale = s
        playlist?.willChangeScale()
        let f = window.frame
        let size = NSSize(width: CGFloat(Layout.size.w) * s, height: CGFloat(Layout.size.h) * s)
        window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        view.scale = s
        playlist?.didChangeScale()
        savePreferences()
    }

    /// The biggest step that still fits the window's screen, at most `maxScale`.
    var largestScale: CGFloat {
        var limit = Self.maxScale
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            limit = min(limit, screen.width / CGFloat(Layout.size.w), screen.height / CGFloat(Layout.size.h))
        }
        return Self.snapScale(limit, backing: window.backingScaleFactor, rule: .down)
    }

    /// Whole screen pixels per skin pixel: half steps on Retina displays, whole steps elsewhere.
    static func snapScale(_ s: CGFloat, backing: CGFloat,
                          rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat {
        guard s.isFinite else { return 1 }
        let step = 1 / max(1, backing.rounded())
        return min(maxScale, max(1, (s / step).rounded(rule) * step))
    }

    /// Moving to a display with a different pixel density: re-snap so the pixels stay square.
    func windowDidChangeBackingProperties(_ notification: Notification) {
        setScale(scale)
        view.needsDisplay = true
    }

    func windowDidMove(_ notification: Notification) {
        savePreferences()
        playlist?.mainDidMove()
    }

    func windowWillMiniaturize(_ notification: Notification) { playlist?.mainWillMiniaturize() }
    func windowDidDeminiaturize(_ notification: Notification) { playlist?.mainDidDeminiaturize() }
    func windowDidBecomeKey(_ notification: Notification) { view?.needsDisplay = true }
    func windowDidResignKey(_ notification: Notification) { view?.needsDisplay = true }

    // MARK: Skins

    func applySkin(_ s: Skin) {
        skin = s
        view.needsDisplay = true
        playlist?.redraw()
    }

    /// Fetches the classic base skin (first launch, or after choosing it from the Skins menu) and
    /// switches to it unless another skin was chosen meanwhile.
    func downloadClassicSkin(announce: Bool) {
        guard skinDownload == nil else { return }
        if announce { show("DOWNLOADING THE CLASSIC SKIN...", seconds: 10) }
        skinDownload = Task { [weak self] in
            do {
                let s = try await ClassicSkin.download()
                guard let self else { return }
                self.skinDownload = nil
                guard self.skinChoice == .classic else { return }
                self.applySkin(s)
                self.show("SKIN: \(s.name.uppercased())", seconds: 2.5)
            } catch {
                guard let self else { return }
                self.skinDownload = nil
                guard self.skinChoice == .classic else { return }
                self.show("COULDN'T DOWNLOAD THE CLASSIC SKIN (\(error.localizedDescription.uppercased())) - USING THE BUILT-IN ONE", seconds: 8)
            }
        }
    }

    // MARK: Preferences

    private func loadPreferences() {
        let d = UserDefaults.standard
        alwaysOnTop = d.bool(forKey: Keys.alwaysOnTop)
        if let saved = d.object(forKey: Keys.scale) as? Double, saved.isFinite {
            scale = min(Self.maxScale, max(1, CGFloat(saved)))
        }
        visMode = VisMode(rawValue: d.integer(forKey: Keys.visMode)) ?? .bars
        timeRemaining = d.bool(forKey: Keys.timeRemaining)
        let path = d.string(forKey: Keys.skinPath)
        skinChoice = d.string(forKey: Keys.skinChoice).flatMap(SkinChoice.init(rawValue:)) ?? (path == nil ? .classic : .file)
        switch skinChoice {
        case .file:
            if let path, let s = try? Skin.load(from: URL(fileURLWithPath: path)) { skin = s }
        case .classic:
            if let s = ClassicSkin.loadCached() { skin = s }
        case .builtin:
            break
        }
    }

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(alwaysOnTop, forKey: Keys.alwaysOnTop)
        d.set(Double(scale), forKey: Keys.scale)
        d.removeObject(forKey: Keys.legacyDoubleSize)
        d.set(visMode.rawValue, forKey: Keys.visMode)
        d.set(timeRemaining, forKey: Keys.timeRemaining)
        d.set(skinChoice.rawValue, forKey: Keys.skinChoice)
        if let w = window { d.set(NSStringFromPoint(NSPoint(x: w.frame.minX, y: w.frame.maxY)), forKey: Keys.windowTopLeft) }
    }
}
