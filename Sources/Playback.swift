import AppKit

/// Starts something specific in Spotify (a track, a playlist, DJ…) without its window jumping to
/// the front. In current versions of the desktop app, AppleScript's `play track` also raises
/// Spotify's window, so Retroamp tries the quiet ways first:
///
/// 1. The Web API (`PUT /me/player/play`), when Spotify is connected. Spotify's servers pass the
///    command on, so the app never comes forward, and a playlist or Liked Songs carries on after
///    the chosen track.
/// 2. `spotify_cli play`, the command-line tool inside Spotify.app (1.3 and later), which drives
///    the running app with your own login.
/// 3. AppleScript, with `FocusGuard` putting Spotify back where it was.
///
/// After each attempt Retroamp checks what Spotify then reports and tries the next way if
/// nothing changed.
@MainActor
final class Playback {
    enum What: Equatable {
        /// A track, episode, album, playlist, artist or show.
        case item(String)
        /// A track inside a playlist or Liked Songs. `following` is the list from that track on,
        /// played instead if the Web API refuses the context.
        case track(String, context: String, following: [String])
        /// Spotify's AI DJ.
        case dj

        /// The track or episode Spotify should end up on, when that's known.
        var trackURI: String? {
            switch self {
            case .item(let uri): return SpotifyLink.isTrackLike(uri) ? uri : nil
            case .track(let uri, _, _): return uri
            case .dj: return nil
            }
        }
    }

    enum Method: String { case webAPI = "the Web API", cli = "spotify_cli", appleScript = "AppleScript" }

    private unowned let spotify: PlayerBridge
    weak var api: SpotifyWebAPI?
    let focus = FocusGuard()
    /// Marquee text and how long to show it.
    var onMessage: ((String, Double) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0                  // counts starts, so a late DJ press can't undo a newer one
    private var lastDJPress: TimeInterval = -10
    private var launchedAt: TimeInterval?       // Retroamp opened Spotify and it isn't ready yet
    private var frontAtLaunch: NSRunningApplication?
    private var problem: String?                // why an attempt failed, for the marquee

    init(spotify: PlayerBridge) { self.spotify = spotify }

    /// Starts `what`, replacing a start that's still under way. `done` learns whether it played.
    func start(_ what: What, done: ((Bool) -> Void)? = nil) {
        generation += 1
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let ok = await self.run(what)
            guard !Task.isCancelled else { return }
            if !ok {
                let headline = what == .dj ? "COULDN'T START SPOTIFY DJ" : "COULDN'T PLAY IT"
                self.onMessage?(headline + (self.problem.map { ": " + $0.uppercased() } ?? ""), 6)
            }
            done?(ok)
        }
    }

    /// The DJ button (the Winamp logo, ⌘J). Starts DJ; while DJ is on, starts it again from the
    /// top, which asks it for a fresh set. Spotify's own DJ button ("Get some different DJ picks")
    /// can't be pressed from outside its app, so this is the nearest thing.
    func startDJ(done: ((Bool) -> Void)? = nil) {
        let now = AppDelegate.now
        guard now - lastDJPress > 1.5 else { return }  // a double-click is one press
        lastDJPress = now
        let pressedAt = generation
        Task { [weak self] in
            guard let self else { return }
            let on = await self.isDJOn()
            guard pressedAt == self.generation else { return }  // something else was started meanwhile
            self.onMessage?(on == true ? "SPOTIFY DJ: GETTING DIFFERENT PICKS..." : "STARTING SPOTIFY DJ...", 4)
            self.start(.dj, done: done)
        }
    }

    /// Whether Spotify is playing from DJ, or paused in it. Nil if there's no telling.
    func isDJOn() async -> Bool? {
        guard spotify.isRunning else { return false }
        if SpotifyCLI.isAvailable, let out = await SpotifyCLI.run(["now-playing", "--format", "json"], timeout: 3),
           out.status == 0, let on = SpotifyCLI.isDJ(nowPlayingJSON: out.stdout) {
            return on
        }
        if let api, api.isConnected {
            do { return try await api.playingContextURI() == SpotifyLink.djURI } catch { return nil }
        }
        return nil
    }

    /// The ways to try, best first.
    static func order(for what: What, webAPI: Bool, cli: Bool) -> [Method] {
        switch what {
        case .item:
            return (webAPI ? [.webAPI] : []) + (cli ? [.cli] : []) + [.appleScript]
        case .track:
            // spotify_cli can only start the track on its own, so AppleScript, which keeps the
            // playlist going, comes before it.
            return (webAPI ? [.webAPI] : []) + [.appleScript] + (cli ? [.cli] : [])
        case .dj:
            // Starting the DJ playlist through the Web API is reported to stop playback instead.
            return (cli ? [.cli] : []) + [.appleScript]
        }
    }

    private func run(_ what: What) async -> Bool {
        problem = nil
        if !spotify.isRunning {
            guard spotify.isInstalled else {
                problem = "Spotify isn't installed"
                return false
            }
            frontAtLaunch = NSWorkspace.shared.frontmostApplication
            spotify.launch(thenPlay: false, hidden: true)
            launchedAt = AppDelegate.now
        }
        if launchedAt != nil {
            guard await waitUntilReady() else { return false }
        }
        spotify.poll()
        let before = spotify.status, beforePosition = spotify.position
        let methods = Self.order(for: what, webAPI: api?.isConnected == true, cli: SpotifyCLI.isAvailable)
        for (i, method) in methods.enumerated() {
            guard !Task.isCancelled else { return false }
            focus.arm()
            let sentAt = AppDelegate.now
            let sent: Bool
            switch method {
            case .webAPI: sent = await viaWebAPI(what)
            case .cli: sent = await viaCLI(what)
            case .appleScript: sent = viaAppleScript(what)
            }
            guard !Task.isCancelled else { return false }
            guard sent else { continue }
            spotify.refreshSoon()
            if i == methods.count - 1 { return true }
            // DJ may take a moment over its intro.
            if await started(what, before: before, beforePosition: beforePosition, sentAt: sentAt,
                             timeout: what == .dj ? 6 : 3.5) { return true }
            NSLog("Retroamp: playback didn't start through %@; trying the next way", method.rawValue)
        }
        return false
    }

    // MARK: Spotify starting up

    /// After opening Spotify: waits until it's signed in, then gives the player a moment. Spotify
    /// is kept in the background meanwhile, unless you click or type.
    private func waitUntilReady() async -> Bool {
        guard let launched = launchedAt else { return true }
        var ready = false
        var signedOutSince: TimeInterval?
        var cliFailures = 0
        while !ready, AppDelegate.now - launched < 40 {
            if Task.isCancelled { return false }
            if spotify.isRunning {
                focus.armForLaunch(frontmost: frontAtLaunch, since: launched)
                if SpotifyCLI.isAvailable, cliFailures < 10 {
                    if let s = await SpotifyCLI.status() {
                        cliFailures = 0
                        if s.loggedIn {
                            ready = true
                        } else if s.running {
                            let since = signedOutSince ?? AppDelegate.now
                            signedOutSince = since
                            if AppDelegate.now - since > 15 {
                                // It's waiting for a sign-in, which needs its window.
                                launchedAt = nil
                                focus.disarm()
                                spotify.activate()
                                problem = "sign in to Spotify first"
                                return false
                            }
                        }
                    } else {
                        cliFailures += 1  // after about 5 s without an answer, ask AppleScript instead
                    }
                } else {
                    spotify.poll()
                    ready = spotify.status.running
                }
            }
            if !ready { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        launchedAt = nil
        guard ready else {
            problem = "Spotify took too long to start"
            return false
        }
        focus.armForLaunch(frontmost: frontAtLaunch, since: launched, for: 2.5)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return !Task.isCancelled
    }

    // MARK: Checking that it worked

    /// Polls Spotify after a command until it reports the change, for up to `timeout` seconds.
    private func started(_ what: What, before: PlayerStatus, beforePosition: Double, sentAt: TimeInterval,
                         timeout: TimeInterval = 3.5) async -> Bool {
        while AppDelegate.now - sentAt < timeout {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return true }  // something else was started meanwhile
            spotify.poll()
            if spotify.automationDenied { return true }  // there's no way to tell, so don't try again
            if Self.didStart(what, before: before, beforePosition: beforePosition, now: spotify.status,
                             position: spotify.position, elapsed: AppDelegate.now - sentAt) { return true }
        }
        return false
    }

    /// Whether Spotify's state shows that `what` started.
    static func didStart(_ what: What, before: PlayerStatus, beforePosition: Double, now: PlayerStatus,
                         position: Double, elapsed: Double) -> Bool {
        guard now.running, now.state == .playing, !now.trackID.isEmpty else { return false }
        if now.trackID != before.trackID { return true }
        if let t = what.trackURI, t != now.trackID { return false }  // still on the old track
        if before.state != .playing { return true }
        return position < elapsed + 1.5 && beforePosition > position + 1  // the same track, restarted
    }

    // MARK: The Web API

    private func viaWebAPI(_ what: What) async -> Bool {
        guard let api, api.isConnected else { return false }
        let bodies = Self.requestBodies(for: what)
        var device: String?, lookedUp = false, i = 0
        while i < bodies.count, !Task.isCancelled {
            do {
                try await api.startPlayback(bodies[i], deviceID: device)
                return true
            } catch WebAPIError.http(404, _) where !lookedUp {
                // No device is active (Spotify has been idle for a while): play on this Mac.
                lookedUp = true
                guard let id = await localDeviceID(api) else {
                    problem = problem ?? "Spotify on this Mac isn't listed as a device yet"
                    return false
                }
                device = id
            } catch WebAPIError.http(let code, let why) where (400..<500).contains(code) && i + 1 < bodies.count {
                NSLog("Retroamp: the Web API refused the context (%d %@); playing the list instead", code, why)
                i += 1
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NSLog("Retroamp: Web API playback failed: %@", text)
                problem = problem ?? text
                return false
            }
        }
        return false
    }

    /// Bodies for `PUT /me/player/play`, best first.
    static func requestBodies(for what: What) -> [[String: Any]] {
        switch what {
        case .item(let uri):
            return [SpotifyLink.isTrackLike(uri) ? ["uris": [uri]] : ["context_uri": uri]]
        case .track(let uri, let context, let following):
            var bodies: [[String: Any]] = [["context_uri": context, "offset": ["uri": uri]]]
            // Liked Songs isn't an official context; if it's refused, play the list from this track.
            let list = following.first == uri ? following : [uri] + following
            bodies.append(["uris": Array(list.filter(SpotifyLink.isTrackLike).prefix(50))])
            return bodies
        case .dj:
            return []
        }
    }

    private func localDeviceID(_ api: SpotifyWebAPI) async -> String? {
        guard let devices = try? await api.devices(), !devices.isEmpty else { return nil }
        let selfID = await SpotifyCLI.selfDeviceID()
        let name: String? = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: Host.current().localizedName) }
        }
        return Self.pickDevice(devices, selfID: selfID, computerName: name)
    }

    /// This Mac's Spotify among the Web API's devices: by the ID spotify_cli reports for it, by the
    /// computer's name, or the only computer listed.
    static func pickDevice(_ devices: [SpotifyWebAPI.Device], selfID: String?, computerName: String?) -> String? {
        if let selfID, devices.contains(where: { $0.id == selfID }) { return selfID }
        let computers = devices.filter { $0.type.caseInsensitiveCompare("Computer") == .orderedSame }
        if let name = computerName, let d = computers.first(where: { $0.name == name }) { return d.id }
        return computers.count == 1 ? computers[0].id : nil
    }

    // MARK: spotify_cli and AppleScript

    private func viaCLI(_ what: What) async -> Bool {
        let uri: String
        switch what {
        case .item(let u), .track(let u, _, _): uri = u
        case .dj: uri = SpotifyLink.djURI
        }
        guard let safe = SpotifyLink.sanitized(uri) else { return false }
        guard let out = await SpotifyCLI.run(["play", safe]) else {
            problem = problem ?? "spotify_cli didn't answer"
            return false
        }
        guard out.status == 0 else {
            NSLog("Retroamp: spotify_cli play failed (%d): %@", out.status, out.errorLine)
            problem = problem ?? out.errorLine
            return false
        }
        return true
    }

    private func viaAppleScript(_ what: What) -> Bool {
        switch what {
        case .item(let uri): return spotify.playTrackCommand(uri)
        case .track(let uri, let context, _): return spotify.playTrackCommand(uri, inContext: context)
        case .dj: return spotify.playTrackCommand(SpotifyLink.djURI)
        }
    }
}

// MARK: - spotify_cli

/// `spotify_cli`, the undocumented command-line tool inside Spotify.app since version 1.3. It
/// controls the running app with the user's own login, so it doesn't need the Web API. Flags go
/// after the command (`status --format json`); errors go to stderr with exit status 1.
enum SpotifyCLI {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String

        /// The first thing it printed to stderr, which is its error message.
        var errorLine: String {
            stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "error \(status)"
        }
    }

    @MainActor static var url: URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Backend.spotify.bundleID) else { return nil }
        let tool = app.appendingPathComponent("Contents/MacOS/spotify_cli")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    @MainActor static var isAvailable: Bool { url != nil }

    /// Runs the tool off the main thread. Nil if it couldn't start or took longer than `timeout`.
    @MainActor static func run(_ arguments: [String], timeout: TimeInterval = 8) async -> Output? {
        guard let url else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: execute(url, arguments, timeout: timeout))
            }
        }
    }

    /// From `now-playing --format json`: whether Spotify is playing from DJ, whose name it gives as
    /// the context. False if nothing is playing, nil if the output isn't what's expected.
    static func isDJ(nowPlayingJSON text: String) -> Bool? {
        guard let j = json(text) else { return nil }
        switch j["currently_playing"] {
        case let item as [String: Any]:
            let context = (item["context_description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return context.caseInsensitiveCompare("DJ") == .orderedSame
        case is NSNull:
            return false
        default:
            return nil
        }
    }

    @MainActor static func status() async -> (running: Bool, loggedIn: Bool)? {
        guard let out = await run(["status", "--format", "json"], timeout: 5), out.status == 0,
              let j = json(out.stdout) else { return nil }
        return (j["running"] as? Bool ?? false, j["logged_in"] as? Bool ?? false)
    }

    /// The Spotify Connect ID of this Mac's Spotify.
    @MainActor static func selfDeviceID() async -> String? {
        guard let out = await run(["devices", "--format", "json"], timeout: 5), out.status == 0 else { return nil }
        return selfDeviceID(fromJSON: out.stdout)
    }

    static func selfDeviceID(fromJSON text: String) -> String? {
        for case let d as [String: Any] in json(text)?["devices"] as? [Any] ?? [] where d["is_self"] as? Bool == true {
            if let id = d["device_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Runs a program without a shell and collects its output. Blocks; nil if it can't be
    /// started or outlives `timeout`, in which case it's killed.
    static func execute(_ url: URL, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }

        // Drain both pipes as it runs, so a full pipe can't stall it. They close when it exits.
        let collected = Collected()
        let group = DispatchGroup()
        for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                collected.set(handle.readDataToEndOfFile(), isError: isError)
                group.leave()
            }
        }
        guard group.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if group.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        process.waitUntilExit()
        let (o, e) = collected.get()
        return Output(status: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        func set(_ data: Data, isError: Bool) {
            lock.lock()
            if isError { err = data } else { out = data }
            lock.unlock()
        }

        func get() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (out, err)
        }
    }
}

// MARK: - Focus guard

/// Undoes Spotify coming to the front after a play command. If it was hidden or had no window
/// open, it's hidden again; either way the focus goes back to the app that had it. It stands down
/// as soon as you click or type, so bringing Spotify up yourself still works.
@MainActor
final class FocusGuard: NSObject {
    private struct Before {
        let spotify: NSRunningApplication
        let wasHidden: Bool
        let hadWindow: Bool
        let frontmost: NSRunningApplication?
        let armedAt: TimeInterval
    }

    private var before: Before?
    private var until: TimeInterval = 0
    private var lastFix: TimeInterval = 0
    private var timer: Timer?

    /// Watches Spotify for the next few seconds. Re-arming while armed only extends the watch.
    func arm(for seconds: TimeInterval = 4) {
        if extend(by: seconds) { return }
        guard let spotify = Self.spotifyApp, !spotify.isActive else { return }  // already in front: nothing to give back
        watch(Before(spotify: spotify, wasHidden: spotify.isHidden,
                     hadWindow: Self.hasWindowOnScreen(spotify.processIdentifier),
                     frontmost: NSWorkspace.shared.frontmostApplication, armedAt: AppDelegate.now), for: seconds)
    }

    /// While Spotify starts up hidden at Retroamp's request: keeps it hidden and the focus with
    /// `frontmost`, unless you've clicked or typed since `since`. Call it again to keep watching.
    func armForLaunch(frontmost: NSRunningApplication?, since: TimeInterval, for seconds: TimeInterval = 2) {
        if extend(by: seconds) { return }
        guard let spotify = Self.spotifyApp else { return }
        watch(Before(spotify: spotify, wasHidden: true, hadWindow: false, frontmost: frontmost, armedAt: since),
              for: seconds)
    }

    private static var spotifyApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Backend.spotify.bundleID).first
    }

    private func extend(by seconds: TimeInterval) -> Bool {
        let now = AppDelegate.now
        guard before != nil, now < until else { return false }
        until = max(until, now + seconds)
        return true
    }

    private func watch(_ snapshot: Before, for seconds: TimeInterval) {
        disarm()
        before = snapshot
        until = AppDelegate.now + seconds
        let t = Timer(timeInterval: 0.05, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(check(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(check(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
    }

    /// Stops watching, e.g. before bringing Spotify up on purpose.
    func disarm() {
        before = nil
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func check(_ sender: Any?) {
        guard let b = before else { return disarm() }
        let now = AppDelegate.now
        guard now < until, !b.spotify.isTerminated else { return disarm() }
        // A click or key press since the command means you've moved on (maybe to Spotify itself).
        if Self.secondsSinceInput() < now - b.armedAt - 0.05 { return disarm() }
        let tookFocus = b.spotify.isActive
        let unhid = b.wasHidden && !b.spotify.isHidden
        let windowAppeared = !b.wasHidden && !b.hadWindow && Self.hasWindowOnScreen(b.spotify.processIdentifier)
        guard tookFocus || unhid || windowAppeared, now - lastFix > 0.25 else { return }
        lastFix = now
        if b.wasHidden || !b.hadWindow { b.spotify.hide() }
        if tookFocus, let front = b.frontmost, front != b.spotify, !front.isTerminated {
            if front == NSRunningApplication.current {
                NSApp.activate()
                // If macOS turns the activation down, at least don't leave Retroamp covered.
                for w in NSApp.windows where w.isVisible { w.orderFrontRegardless() }
            } else {
                front.activate(options: [])
            }
        }
    }

    /// Seconds since the last click or key press anywhere.
    static func secondsSinceInput() -> TimeInterval {
        let kinds: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    /// Whether the app has a normal, visible window on the current screen and Space.
    static func hasWindowOnScreen(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.width >= 50 && rect.height >= 50
        }
    }
}
