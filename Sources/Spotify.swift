import AppKit

struct PlayerStatus {
    var running = false
    var state: PlaybackState = .stopped
    var position: Double = 0        // seconds
    var volume = 50                 // 0…100
    var shuffle = false
    var repeating = false
    var trackID = ""                // spotify:track:… or Music's persistent ID
    var name = ""
    var artist = ""
    var album = ""
    var duration: Double = 0        // seconds
}

/// The player app Retroamp drives. Spotify's AppleScript dictionary copies iTunes', which Music
/// still has, so the two differ only in a few terms.
enum Backend: String {
    case spotify, music

    /// The name AppleScript addresses.
    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var displayName: String { self == .spotify ? "Spotify" : "Apple Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    /// Distributed notification posted on every play, pause and track change.
    var notification: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }

    fileprivate var shuffleTerm: String { self == .spotify ? "shuffling" : "shuffle enabled" }
    fileprivate var repeatGet: String { self == .spotify ? "repeating" : "(song repeat is not off)" }
    fileprivate func repeatSet(_ on: Bool) -> String {
        self == .spotify ? "set repeating to \(on)" : "set song repeat to \(on ? "all" : "off")"
    }
    fileprivate var trackIDTerm: String { self == .spotify ? "id" : "persistent ID" }
}

/// Talks to the player app (Spotify or Music) through its AppleScript dictionary.
/// All calls run on the main thread; each one is a short Apple Event round trip.
@MainActor
final class PlayerBridge: NSObject {
    let backend: Backend
    private var name: String { backend.appName }

    init(_ backend: Backend) { self.backend = backend }

    private(set) var status = PlayerStatus()
    private var polledAt = ProcessInfo.processInfo.systemUptime
    private var compiled: [String: NSAppleScript] = [:]
    private var pendingPlayUntil: TimeInterval?
    private(set) var automationDenied = false
    private var lastDeniedPoll: TimeInterval = 0
    private var skipTask: Task<Void, Never>?

    /// Short status line for the marquee ("VOLUME: 40%", errors, …).
    var onMessage: ((String) -> Void)?

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: backend.bundleID).isEmpty
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: backend.bundleID) != nil }

    /// Position extrapolated from the last poll while playing.
    var position: Double {
        guard status.state == .playing else { return status.position }
        let p = status.position + (ProcessInfo.processInfo.systemUptime - polledAt)
        return status.duration > 0 ? min(p, status.duration) : p
    }

    // MARK: Polling

    var pollSource: String { """
    if application "\(name)" is running then
        with timeout of 3 seconds
            tell application "\(name)"
                -- not "st": macOS 26 reserves it ("1st"), so the script wouldn't compile
                set pstate to player state
                set pos to 0
                try
                    set pos to player position
                end try
                set vol to sound volume
                set sh to \(backend.shuffleTerm)
                set rp to \(backend.repeatGet)
                set tid to ""
                set tname to ""
                set tartist to ""
                set talbum to ""
                set tdur to 0
                try
                    set t to current track
                    set tid to \(backend.trackIDTerm) of t
                    set tname to name of t
                    set tartist to artist of t
                    set talbum to album of t
                    set tdur to duration of t
                end try
                return {pstate, pos, vol, sh, rp, tid, tname, tartist, talbum, tdur}
            end tell
        end timeout
    end if
    return "not running"
    """ }

    func poll() {
        guard isRunning else {
            if status.running { status = PlayerStatus() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if automationDenied, now - lastDeniedPoll < 5 { return }
        lastDeniedPoll = now

        guard let d = run(pollSource, key: "poll"), d.descriptorType == fourCC("list"), d.numberOfItems >= 10 else {
            return
        }
        automationDenied = false
        var s = PlayerStatus(running: true)
        switch d.atIndex(1)?.enumCodeValue {
        case fourCC("kPSP"): s.state = .playing
        case fourCC("kPSp"): s.state = .paused
        default: s.state = .stopped
        }
        s.position = d.atIndex(2)?.doubleValue ?? 0
        s.volume = Int(d.atIndex(3)?.int32Value ?? 50)
        s.shuffle = d.atIndex(4)?.booleanValue ?? false
        s.repeating = d.atIndex(5)?.booleanValue ?? false
        s.trackID = d.atIndex(6)?.stringValue ?? ""
        s.name = d.atIndex(7)?.stringValue ?? ""
        s.artist = d.atIndex(8)?.stringValue ?? ""
        s.album = d.atIndex(9)?.stringValue ?? ""
        // The dictionary says seconds, but Spotify reports milliseconds. Music reports seconds.
        let rawDuration = d.atIndex(10)?.doubleValue ?? 0
        let seconds = backend == .music || (rawDuration > 0 && rawDuration < 3000)
        s.duration = seconds ? rawDuration : rawDuration / 1000
        status = s
        polledAt = now

        if let until = pendingPlayUntil {
            if now > until { pendingPlayUntil = nil } else if s.state != .playing {
                pendingPlayUntil = nil
                play()
            }
        }
    }

    /// Applies the app's notification details right away (no Apple Events needed). Music's track
    /// ID comes in another form, so the poll that follows fills it in.
    func apply(notification info: [AnyHashable: Any]) {
        var s = status
        s.running = true
        switch info["Player State"] as? String {
        case "Playing": s.state = .playing
        case "Paused": s.state = .paused
        case "Stopped": s.state = .stopped
        default: break
        }
        if let v = info["Track ID"] as? String { s.trackID = v }
        if let v = info["Name"] as? String { s.name = v }
        if let v = info["Artist"] as? String { s.artist = v }
        if let v = info["Album"] as? String { s.album = v }
        if let v = info["Duration"] as? NSNumber { s.duration = v.doubleValue / 1000 }
        if let v = info["Total Time"] as? NSNumber { s.duration = v.doubleValue / 1000 }  // Music
        if let v = info["Playback Position"] as? NSNumber { s.position = v.doubleValue; polledAt = ProcessInfo.processInfo.systemUptime }
        status = s
    }

    /// Polls again shortly after a command, once Spotify has caught up.
    func refreshSoon() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshNow), object: nil)
        perform(#selector(refreshNow), with: nil, afterDelay: 0.15)
        perform(#selector(refreshNow), with: nil, afterDelay: 0.6)
    }

    @objc private func refreshNow() { poll() }

    // MARK: Commands

    func playPause() { command("playpause", key: "playpause") }
    func pause() { command("pause", key: "pause") }
    func next() { command("next track", key: "next") }
    func previous() { command("previous track", key: "previous") }

    func play() {
        if isRunning { command("play", key: "play") } else { launch(thenPlay: true) }
    }

    func stop() {
        if backend == .music {
            command("stop", key: "stop")
            status.state = .stopped
        } else {
            command("pause\nset player position to 0", key: "stop")
            status.state = .paused
        }
        status.position = 0
    }

    func setVolume(_ v: Int) {
        let v = max(0, min(100, v))
        status.volume = v
        command("set sound volume to \(v)", refresh: false)
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds)
        command("set player position to \(String(format: "%.2f", s))")
        status.position = s
        polledAt = ProcessInfo.processInfo.systemUptime
    }

    func setShuffle(_ on: Bool) { status.shuffle = on; command("set \(backend.shuffleTerm) to \(on)") }
    func setRepeat(_ on: Bool) { status.repeating = on; command(backend.repeatSet(on)) }

    /// Music: plays one of your playlists, or a track inside it so Music carries on with the
    /// playlist. IDs are Music's persistent IDs (hex).
    @discardableResult
    func playMusic(playlist: String, track: String? = nil) -> Bool {
        guard let p = MusicLibrary.sanitized(playlist) else { return false }
        let list = "(first playlist whose persistent ID is \"\(p)\")"
        guard let track else { return command("play \(list)") }
        guard let t = MusicLibrary.sanitized(track) else { return false }
        return command("play (first track of \(list) whose persistent ID is \"\(t)\")")
    }

    /// AppleScript's `play track` for a sanitized spotify: URI (track, album, playlist, artist,
    /// show or episode), optionally inside a playlist or collection so Spotify carries on with what
    /// follows. Current versions of Spotify also bring their window to the front for this one, so
    /// it's `Playback`'s last resort. Returns whether the command went through.
    @discardableResult
    func playTrackCommand(_ uri: String, inContext context: String? = nil) -> Bool {
        guard let track = SpotifyLink.sanitized(uri) else { return false }
        guard let context else { return command("play track \"\(track)\"") }
        guard let ctx = SpotifyLink.sanitized(context) else { return false }
        return command("play track \"\(track)\" in context \"\(ctx)\"")
    }

    /// Skips forward through the queue, one track at a time (Spotify has no "play queue item" command).
    func skip(times: Int) {
        let n = max(0, min(times, 50))
        guard n > 0 else { return }
        skipTask?.cancel()
        skipTask = Task { @MainActor [weak self] in
            for i in 0..<n {
                if i > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
                guard !Task.isCancelled, let self else { return }
                self.command("next track", key: "next", refresh: i == n - 1)
            }
        }
    }

    func activate() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: backend.bundleID).first {
            _ = app.activate(options: [])
        } else {
            launch(thenPlay: false)
        }
    }

    /// Opens the app in the background; `hidden` also keeps its window out of sight.
    func launch(thenPlay: Bool, hidden: Bool = false) {
        let upper = backend.displayName.uppercased()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: backend.bundleID) else {
            onMessage?("\(upper) IS NOT INSTALLED")
            return
        }
        onMessage?("STARTING \(upper)...")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = hidden
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        if thenPlay { pendingPlayUntil = ProcessInfo.processInfo.systemUptime + 20 }
    }

    // MARK: AppleScript plumbing

    /// Runs a command inside `tell application "…"`; false if the app isn't running or it failed.
    @discardableResult
    private func command(_ body: String, key: String? = nil, refresh: Bool = true) -> Bool {
        guard isRunning else { return false }
        let source = """
        if application "\(name)" is running then
            with timeout of 3 seconds
                tell application "\(name)"
                    \(body)
                end tell
            end timeout
        end if
        """
        let ok = run(source, key: key) != nil
        if refresh { refreshSoon() }
        return ok
    }

    @discardableResult
    private func run(_ source: String, key: String?) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let key, let cached = compiled[key] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var err: NSDictionary?
            guard s.compileAndReturnError(&err) else { report(err); return nil }
            script = s
            if let key { compiled[key] = s }
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err { report(err); return nil }
        return result
    }

    private func report(_ err: NSDictionary?) {
        let code = (err?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        switch code {
        case -1743:
            if !automationDenied {
                onMessage?("ALLOW RETROAMP TO CONTROL \(name.uppercased()): SYSTEM SETTINGS > PRIVACY & SECURITY > AUTOMATION")
            }
            automationDenied = true
        case -600, -609, -1712:
            break  // The app quit or is busy; the next poll recovers.
        default:
            let msg = (err?[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
            NSLog("Retroamp AppleScript error %d: %@", code, msg)
        }
    }
}

func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

/// Turns open.spotify.com links and spotify: URIs into canonical spotify:type:id URIs.
enum SpotifyLink {
    static let types: Set<String> = ["track", "album", "playlist", "artist", "episode", "show"]

    /// Spotify's AI DJ is played as this playlist; Spotify's own player checks for the same URI.
    static let djURI = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"

    /// Keeps only characters that can't escape an AppleScript string; nil unless it's a spotify: URI.
    static func sanitized(_ uri: String) -> String? {
        let safe = String(uri.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ":_-.%".contains($0)) })
        return safe.hasPrefix("spotify:") && safe.count > 8 ? safe : nil
    }

    /// Tracks and episodes play on their own; everything else is a context (album, playlist…).
    static func isTrackLike(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:")
    }

    static func uri(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("spotify:") {
            let parts = s.split(separator: ":").map(String.init)
            guard let i = parts.lastIndex(where: { types.contains($0.lowercased()) }), i + 1 < parts.count else { return nil }
            return make(parts[i].lowercased(), parts[i + 1])
        }
        guard let comps = URLComponents(string: s), let host = comps.host?.lowercased(),
              host == "open.spotify.com" || host == "play.spotify.com" else { return nil }
        let path = comps.path.split(separator: "/").map(String.init)
        for (i, p) in path.enumerated() where types.contains(p.lowercased()) && i + 1 < path.count {
            if let u = make(p.lowercased(), path[i + 1]) { return u }
        }
        return nil
    }

    private static func make(_ type: String, _ rawID: String) -> String? {
        let id = String(rawID.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return id.isEmpty ? nil : "spotify:\(type):\(id)"
    }

    static func webURL(for uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }
}
