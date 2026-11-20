import AppKit
import CoreAudio

/// `Retroamp --selftest`: checks the sign-in plumbing, Web API parsing and the visualizer without a
/// browser, a Spotify account or audio hardware. The redirect listener runs on a spare port, so a
/// running Retroamp is unaffected.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let d = detail()
        print((ok ? "PASS " : "FAIL ") + name + (ok || d.isEmpty ? "" : " (\(d))"))
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        loopback()
        pkce()
        parsing()
        playback()
        windowSize()
        visualizer()
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    // MARK: Redirect listener

    private final class Box: @unchecked Sendable {
        var outcome: LoopbackServer.Outcome?
        let done = DispatchSemaphore(value: 0)
    }

    private static func serve(_ server: LoopbackServer, state: String, seconds: TimeInterval = 20) -> Box {
        let box = Box()
        Thread.detachNewThread {
            box.outcome = server.serve(state: state, deadline: Date().addingTimeInterval(seconds))
            box.done.signal()
        }
        return box
    }

    private static func loopback() {
        let port: UInt16 = 43276
        let state = PKCE.randomString(32)
        let server = LoopbackServer(port: port)
        do { try server.start() } catch {
            check("listener starts on 127.0.0.1:\(port)", false, error.localizedDescription)
            return
        }
        let box = serve(server, state: state)

        // A browser may open a connection and send nothing; the real request must still get through.
        let idle = connect(port)
        check("idle connection accepted", idle >= 0)
        let t0 = Date()
        let notFound = request(port, "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        check("other paths get 404", notFound.hasPrefix("HTTP/1.1 404 "), firstLine(notFound))
        check("not held up by the idle connection", Date().timeIntervalSince(t0) < 1.5,
              String(format: "%.1f s", Date().timeIntervalSince(t0)))
        let post = request(port, "POST /callback?code=x&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n")
        check("POST gets 404", post.hasPrefix("HTTP/1.1 404 "), firstLine(post))
        let wrong = request(port, "GET /callback?code=x&state=wrong HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        check("wrong state gets 400", wrong.hasPrefix("HTTP/1.1 400 "), firstLine(wrong))
        check("still waiting after bad requests", box.outcome == nil)
        let ok = request(port, "GET /callback?code=AQ-the_code&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        check("callback gets 200", ok.hasPrefix("HTTP/1.1 200 "), firstLine(ok))
        check("response has a strict CSP", ok.contains("Content-Security-Policy: default-src 'none'"))
        check("response isn't cached", ok.contains("Cache-Control: no-store"))
        _ = box.done.wait(timeout: .now() + 5)
        check("returns the code", box.outcome == .code("AQ-the_code"), String(describing: box.outcome))
        if idle >= 0 { close(idle) }
        check("listener closed afterwards", connect(port) < 0)

        // A declined sign-in, with markup in the error that must come back escaped.
        let s2 = LoopbackServer(port: port)
        if (try? s2.start()) != nil {
            let b2 = serve(s2, state: state)
            let denied = request(port, "GET /callback?error=%3Cscript%3Ex&state=\(state) HTTP/1.1\r\n\r\n")
            _ = b2.done.wait(timeout: .now() + 5)
            check("declined sign-in reported", b2.outcome == .denied("<script>x"), String(describing: b2.outcome))
            check("error text is escaped", denied.contains("&lt;script&gt;x") && !denied.contains("<script>"))
        } else {
            check("listener restarts on the same port", false)
        }

        // Cancelling (from the controller's "cancel" row) ends the wait.
        let s3 = LoopbackServer(port: port)
        if (try? s3.start()) != nil {
            let b3 = serve(s3, state: state)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { s3.cancel() }
            _ = b3.done.wait(timeout: .now() + 5)
            check("cancel ends the wait", b3.outcome == .cancelled, String(describing: b3.outcome))
        }

        // A second listener on a busy port fails with a readable message instead of hanging.
        let a = LoopbackServer(port: port), b = LoopbackServer(port: port)
        if (try? a.start()) != nil {
            do {
                try b.start()
                check("busy port detected", false)
            } catch {
                check("busy port detected", error.localizedDescription.contains("in use"), error.localizedDescription)
            }
            a.cancel()
            _ = a.serve(state: state, deadline: Date())
        }
    }

    private static func firstLine(_ s: String) -> String { s.components(separatedBy: "\r\n").first ?? "" }

    private static func connect(_ port: UInt16) -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { close(s); return -1 }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    /// Sends a raw request and reads the response until the server closes the connection.
    private static func request(_ port: UInt16, _ text: String) -> String {
        let s = connect(port)
        guard s >= 0 else { return "(connect failed)" }
        defer { close(s) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { send(s, $0.baseAddress, $0.count, 0) }
        var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: PKCE

    private static func pkce() {
        // RFC 7636, appendix B.
        check("S256 challenge matches RFC 7636",
              PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = PKCE.randomString(64)
        check("verifier is 64 URL-safe characters",
              v.count == 64 && v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        check("verifiers differ", PKCE.randomString(64) != v)
        check("form encoding", SpotifyWebAPI.formEncode(["scope": "a b", "redirect_uri": "http://127.0.0.1:1/c"])
              == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fc&scope=a%20b")
        check("client ID format", SpotifyWebAPI.isValidClientID("0123456789abcdef0123456789ABCDEF")
              && !SpotifyWebAPI.isValidClientID("0123456789abcdef") && !SpotifyWebAPI.isValidClientID(String(repeating: "g", count: 32)))
    }

    // MARK: Parsing

    private static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    private static func parsing() {
        let track = json("""
        {"name":"Song","uri":"spotify:track:abc","duration_ms":225500,"artists":[{"name":"A"},{"name":"B"}]}
        """)
        let e = SpotifyWebAPI.entry(fromItem: track)
        check("track title", e?.title == "A, B - Song", e?.title ?? "nil")
        check("track length", e?.duration == 225.5 && e?.durationText == "3:45", e?.durationText ?? "nil")
        check("track kind", e?.kind == .track && e?.uri == "spotify:track:abc")

        let episode = SpotifyWebAPI.entry(fromItem: json("""
        {"name":"Ep 1","uri":"spotify:episode:e1","duration_ms":3600000,"show":{"name":"Show"},"type":"episode"}
        """))
        check("episode title", episode?.title == "Show - Ep 1", episode?.title ?? "nil")
        check("long length", episode?.durationText == "60:00", episode?.durationText ?? "nil")

        // Playlist items since February 2026 ("item"), older responses ("track"), a local file.
        let page = SpotifyWebAPI.trackPage(json("""
        {"items":[{"item":{"name":"New","uri":"spotify:track:n","duration_ms":1000,"artists":[{"name":"X"}]}},
                  {"track":{"name":"Old","uri":"spotify:track:o","duration_ms":2000,"artists":[{"name":"Y"}]}},
                  {"is_local":true,"item":{"name":"Mine","uri":"spotify:local:Me::Mine:3","duration_ms":3000,"artists":[]}},
                  {"item":null}],
         "next":"https://api.spotify.com/v1/playlists/p/items?offset=50&limit=50","total":120}
        """))
        check("page rows", page.entries.map(\.title) == ["X - New", "Y - Old", "Mine"], "\(page.entries.map(\.title))")
        check("local files marked", page.entries.last?.kind == .local)
        check("page total and next", page.total == 120 && page.next?.hasPrefix("https://api.spotify.com/v1/") == true)

        check("running time", PlaylistEntry.longTimeString(3725) == "1:02:05" && PlaylistEntry.longTimeString(65) == "1:05")
        check("link sanitizing", SpotifyLink.sanitized("spotify:track:abc\" & quit") == "spotify:track:abcquit"
              && SpotifyLink.sanitized("file:///etc") == nil)
        check("Music ID sanitizing", MusicLibrary.sanitized("542DFBEDEF4B253D") == "542DFBEDEF4B253D"
              && MusicLibrary.sanitized("542DFBEDEF4B253D\" & quit") == nil && MusicLibrary.sanitized("abc") == nil)

        // Compiling reads the app's dictionary without launching it (macOS 26 broke a variable named "st").
        for backend in [Backend.spotify, .music] where PlayerBridge(backend).isInstalled {
            var err: NSDictionary?
            let ok = NSAppleScript(source: PlayerBridge(backend).pollSource)?.compileAndReturnError(&err) == true
            check("\(backend.appName) poll script compiles", ok, "\(err ?? [:])")
        }
    }

    // MARK: Playback

    private static func playback() {
        typealias P = Playback
        func body(_ b: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        }
        let track = P.requestBodies(for: .item("spotify:track:t1")).map(body)
        check("a track link plays on its own", track == [#"{"uris":["spotify:track:t1"]}"#], "\(track)")
        let album = P.requestBodies(for: .item("spotify:album:a1")).map(body)
        check("an album link plays as a context", album == [#"{"context_uri":"spotify:album:a1"}"#], "\(album)")
        let liked = P.requestBodies(for: .track("spotify:track:t2", context: "spotify:user:me:collection",
                                                following: ["spotify:track:t2", "spotify:local:x", "spotify:episode:e"])).map(body)
        check("a playlist track keeps its context, with the list as a fallback",
              liked == [#"{"context_uri":"spotify:user:me:collection","offset":{"uri":"spotify:track:t2"}}"#,
                        #"{"uris":["spotify:track:t2","spotify:episode:e"]}"#], "\(liked)")
        check("DJ doesn't go through the Web API", P.requestBodies(for: .dj).isEmpty)
        check("the DJ playlist", SpotifyLink.djURI == "spotify:playlist:37i9dQZF1EYkqdzj48dyYq" && PlaylistEntry.dj.kind == .dj)
        check("the Winamp logo is the DJ button", Layout.hit(CGPoint(x: 259, y: 98)) == .logo)
        check("now-playing: from DJ", SpotifyCLI.isDJ(nowPlayingJSON: """
        {"currently_playing":{"uri":"spotify:track:a","context_description":"DJ","is_playing":false}}
        """) == true)
        check("now-playing: from a playlist", SpotifyCLI.isDJ(nowPlayingJSON: """
        {"currently_playing":{"uri":"spotify:track:a","context_description":"Discover Weekly","is_playing":true}}
        """) == false)
        check("now-playing: nothing", SpotifyCLI.isDJ(nowPlayingJSON: #"{"currently_playing":null}"#) == false)
        check("now-playing: unreadable", SpotifyCLI.isDJ(nowPlayingJSON: "Spotify isn't running") == nil
              && SpotifyCLI.isDJ(nowPlayingJSON: "{}") == nil)
        check("Web API: playing from DJ", SpotifyWebAPI.contextURI(from: json("""
        {"is_playing":true,"context":{"type":"playlist","uri":"spotify:playlist:37i9dQZF1EYkqdzj48dyYq"}}
        """)) == SpotifyLink.djURI && SpotifyWebAPI.contextURI(from: [:]) == nil)

        check("links: Web API, then spotify_cli, then AppleScript",
              P.order(for: .item("spotify:album:a"), webAPI: true, cli: true) == [.webAPI, .cli, .appleScript])
        check("playlist tracks: AppleScript before spotify_cli, which can't keep the playlist",
              P.order(for: .track("t", context: "c", following: []), webAPI: true, cli: true) == [.webAPI, .appleScript, .cli])
        check("DJ: spotify_cli, then AppleScript", P.order(for: .dj, webAPI: true, cli: true) == [.cli, .appleScript])
        check("without either, AppleScript", P.order(for: .item("spotify:track:t"), webAPI: false, cli: false) == [.appleScript])

        let devices = SpotifyWebAPI.devices(from: json("""
        {"devices":[{"id":"aaa","name":"Phone","type":"Smartphone","is_active":true},
                    {"id":"bbb","name":"Studio","type":"Computer","is_active":false},
                    {"id":null,"name":"Restricted","type":"Speaker"},
                    {"id":"ccc","name":"Laptop","type":"Computer"}]}
        """))
        check("devices without an ID are skipped", devices.map(\.id) == ["aaa", "bbb", "ccc"] && devices[0].isActive,
              "\(devices.map(\.id))")
        check("this Mac by spotify_cli's device ID", P.pickDevice(devices, selfID: "ccc", computerName: "Studio") == "ccc")
        check("this Mac by its name", P.pickDevice(devices, selfID: "zzz", computerName: "Studio") == "bbb")
        check("no guessing between two computers", P.pickDevice(devices, selfID: nil, computerName: "Other") == nil)
        check("the only computer", P.pickDevice(Array(devices.prefix(2)), selfID: nil, computerName: nil) == "bbb")
        check("spotify_cli's own device", SpotifyCLI.selfDeviceID(fromJSON: """
        {"active_device_id":"x","devices":[{"device_id":"other","is_self":false},{"device_id":"mine","is_self":true}]}
        """) == "mine")

        let old = PlayerStatus(running: true, state: .playing, position: 80, trackID: "spotify:track:old")
        func started(_ what: P.What, _ now: PlayerStatus, from before: PlayerStatus = old, after elapsed: Double = 1) -> Bool {
            P.didStart(what, before: before, beforePosition: before.position, now: now, position: now.position, elapsed: elapsed)
        }
        var moved = old
        moved.position = 81
        check("nothing changed: not started", !started(.item("spotify:album:a"), moved))
        var other = old
        other.trackID = "spotify:track:new"
        other.position = 0.5
        check("another track: started", started(.item("spotify:album:a"), other) && started(.dj, other))
        var restarted = old
        restarted.position = 0.8
        check("the same track from the top: started", started(.item("spotify:track:old"), restarted))
        var paused = old
        paused.state = .paused
        check("resuming the old track isn't the new one", !started(.item("spotify:track:new"), moved, from: paused))
        check("playing the paused track: started", started(.item("spotify:track:old"), restarted, from: paused))
        var stopped = other
        stopped.state = .paused
        check("paused on the new track: not yet", !started(.item("spotify:track:new"), stopped))

        let out = SpotifyCLI.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo oops >&2; exit 3"], timeout: 5)
        check("runner collects output and exit status",
              out?.stdout == "out\n" && out?.errorLine == "oops" && out?.status == 3, String(describing: out))
        let t0 = Date()
        let hung = SpotifyCLI.execute(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.5)
        check("runner gives up on a tool that hangs", hung == nil && Date().timeIntervalSince(t0) < 3,
              String(format: "%.1f s", Date().timeIntervalSince(t0)))
    }

    // MARK: Window size

    private static func windowSize() {
        typealias A = AppDelegate
        check("Retina sizes snap to half steps", A.snapScale(1.2, backing: 2) == 1 && A.snapScale(1.3, backing: 2) == 1.5
              && A.snapScale(2.74, backing: 2) == 2.5)
        check("other displays snap to whole steps", A.snapScale(1.4, backing: 1) == 1 && A.snapScale(1.5, backing: 1) == 2)
        check("size limits", A.snapScale(0.2, backing: 2) == 1 && A.snapScale(9, backing: 2) == A.maxScale
              && A.snapScale(.nan, backing: 2) == 1 && A.snapScale(.infinity, backing: 1) == 1)
        check("screen limit rounds down", A.snapScale(2.9, backing: 2, rule: .down) == 2.5)

        let start = NSRect(x: 100, y: 500, width: 275, height: 116)
        check("dragging the right edge", PlayerView.proposedScale(.right, frame: start, moved: CGVector(dx: 137.5, dy: 40)) == 1.5)
        check("dragging the bottom edge down", PlayerView.proposedScale(.bottom, frame: start, moved: CGVector(dx: 500, dy: -116)) == 2)
        check("dragging the corner follows the larger move",
              PlayerView.proposedScale(.corner, frame: start, moved: CGVector(dx: 10, dy: -232)) == 3
              && PlayerView.proposedScale(.corner, frame: start, moved: CGVector(dx: 275, dy: 50)) == 2)

        // The resize zones must never cover a control, at any size.
        var covered: [String] = []
        for s in stride(from: CGFloat(1), through: A.maxScale, by: 0.5) {
            let v = PlayerView(frame: NSRect(x: 0, y: 0, width: 275 * s, height: 116 * s))
            v.scale = s
            for (control, r) in Layout.hitAreas {
                let inView = NSRect(x: r.minX * s, y: (116 - r.maxY) * s, width: r.width * s, height: r.height * s)
                for (edge, zone) in v.resizeZones where zone.intersects(inView) { covered.append("\(edge)/\(control)@\(s)") }
            }
        }
        check("resize zones avoid every control", covered.isEmpty, covered.joined(separator: ", "))
        let v = PlayerView(frame: NSRect(x: 0, y: 0, width: 275, height: 116))
        v.scale = 1
        check("corner and edges resize", v.resizeEdge(at: NSPoint(x: 270, y: 4)) == .corner
              && v.resizeEdge(at: NSPoint(x: 274, y: 60)) == .right && v.resizeEdge(at: NSPoint(x: 120, y: 1)) == .bottom)
        check("title bar and the rest don't", v.resizeEdge(at: NSPoint(x: 274, y: 110)) == nil
              && v.resizeEdge(at: NSPoint(x: 200, y: 50)) == nil && v.resizeEdge(at: NSPoint(x: 260, y: 15)) == nil)
    }

    // MARK: Visualizer

    private enum BufferLayout { case interleaved, perChannel, emptyFirst }

    /// Feeds `chunks` blocks of 512 frames of a 1 kHz sine at -12 dBFS, at 48 kHz, in one of the
    /// buffer layouts an IO proc can get, then draws a few frames.
    private static func tone(_ layout: BufferLayout, chunks: Int = 12) -> Analyzer {
        let a = Analyzer(), frames = 512, rate = 48_000.0
        a.configure(sampleRate: rate, isFloat: true)
        a.resetInputClock()
        let amp = Float(pow(10, -12.0 / 20))
        var phase = 0.0
        for _ in 0..<chunks {
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                mono[f] = amp * Float(sin(phase))
                phase += 2 * .pi * 1000 / rate
            }
            let stereo = mono.flatMap { [$0, $0] }
            switch layout {
            case .interleaved: feed(a, [stereo], channels: 2)
            case .perChannel: feed(a, [mono, mono], channels: 1)
            case .emptyFirst: feed(a, [nil, stereo], channels: 2)
            }
        }
        for _ in 0..<10 { a.update(dt: 1.0 / 30) }
        return a
    }

    /// Calls `ingest` with an AudioBufferList holding `buffers` (nil: a buffer without memory).
    private static func feed(_ a: Analyzer, _ buffers: [[Float]?], channels: UInt32) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var memory: [UnsafeMutablePointer<Float>] = []
        for (i, samples) in buffers.enumerated() {
            guard let samples else {
                list[i] = AudioBuffer(mNumberChannels: channels, mDataByteSize: 0, mData: nil)
                continue
            }
            let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            p.initialize(from: samples, count: samples.count)
            memory.append(p)
            list[i] = AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(samples.count * 4), mData: p)
        }
        a.ingest(list.unsafePointer)
        memory.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    private static func visualizer() {
        let bars = { (a: Analyzer) in a.bars.map { Int($0.rounded()) } }
        let a = tone(.interleaved)
        let top = a.bars.indices.max { a.bars[$0] < a.bars[$1] }
        check("a 1 kHz tone peaks in its band (937-1284 Hz)", top == 10 && a.bars[10] > 12, "\(bars(a))")
        check("nothing at the ends of the spectrum", a.bars[0] < 4 && a.bars[18] < 4, "\(bars(a))")
        check("the oscilloscope swings", (a.osc.max() ?? 0) - (a.osc.min() ?? 0) >= 6, "\(a.osc)")
        check("the tone counts as signal", a.secondsSinceSignal < 1)
        let split = tone(.perChannel)
        check("one buffer per channel", split.bars.indices.max { split.bars[$0] < split.bars[$1] } == 10, "\(bars(split))")
        let skipped = tone(.emptyFirst)
        check("buffers without memory are skipped", skipped.bars.indices.max { skipped.bars[$0] < skipped.bars[$1] } == 10,
              "\(bars(skipped))")

        let quiet = Analyzer()
        quiet.configure(sampleRate: 48_000, isFloat: true)
        quiet.resetInputClock()
        Thread.sleep(forTimeInterval: 0.06)
        feed(quiet, [[Float](repeating: 0, count: 1024)], channels: 2)
        check("silence is input but not signal", quiet.secondsSinceSignal > 0.04 && quiet.secondsSinceInput < 0.04,
              String(format: "signal %.3f s, input %.3f s", quiet.secondsSinceSignal, quiet.secondsSinceInput))

        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<5 { a.update(dt: 0.1) }
        check("bars fall and the scope goes flat when input stops", a.bars.allSatisfy { $0 < 1 } && Set(a.osc).count == 1,
              "\(bars(a)) \(a.osc)")

        typealias D = AudioTap.Device
        let speakers = D(id: 74, uid: "BuiltInSpeakerDevice", outputs: 1, transport: kAudioDeviceTransportTypeBuiltIn)
        let mic = D(id: 80, uid: "BuiltInMicrophoneDevice", inputs: 1, transport: kAudioDeviceTransportTypeBuiltIn)
        let display = D(id: 86, uid: "display", outputs: 1, transport: kAudioDeviceTransportTypeDisplayPort)
        let headset = D(id: 90, uid: "headset", inputs: 1, outputs: 1, transport: kAudioDeviceTransportTypeBluetooth)
        let multi = D(id: 95, uid: "multi", outputs: 2, transport: kAudioDeviceTransportTypeAggregate)
        let airplay = D(id: 99, uid: "airplay", outputs: 1, transport: kAudioDeviceTransportTypeAirPlay)
        let all = [mic, display, headset, multi, airplay, speakers]
        func clock(_ id: AudioObjectID, _ devices: [D] = all) -> AudioObjectID? {
            AudioTap.pickClock(defaultOutput: id, devices: devices)?.id
        }
        check("clock: the default output when it has no microphone", clock(86) == 86 && clock(74) == 74)
        check("clock: built-in speakers instead of a headset's microphone", clock(90) == 74)
        check("clock: never an aggregate device", clock(95) == 74)
        check("clock: AirPlay only as the default output", clock(99) == 99 && clock(90, [headset, airplay]) == nil)
        check("clock: none when every output has a microphone", clock(90, [headset, mic]) == nil)
        var hidden = speakers, dead = display
        hidden.hidden = true
        dead.alive = false
        check("clock: hidden and dead devices skipped", clock(86, [hidden, dead, headset]) == nil)

        let clocked = AudioTap.aggregateDescription(tapUID: "T", clock: speakers)
        let taps = clocked[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        let subs = clocked[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        check("aggregate: created with the tap, drift-compensated",
              taps?.count == 1 && taps?[0][kAudioSubTapUIDKey] as? String == "T"
              && taps?[0][kAudioSubTapDriftCompensationKey] as? Bool == true)
        check("aggregate: clocked by the output device",
              clocked[kAudioAggregateDeviceMainSubDeviceKey] as? String == speakers.uid
              && subs?.count == 1 && subs?[0][kAudioSubDeviceUIDKey] as? String == speakers.uid)
        let tapOnly = AudioTap.aggregateDescription(tapUID: "T", clock: nil)
        check("aggregate: private, starts the tap, tap only without a clock",
              tapOnly[kAudioAggregateDeviceIsPrivateKey] as? Bool == true
              && tapOnly[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true
              && tapOnly[kAudioAggregateDeviceMainSubDeviceKey] == nil && tapOnly[kAudioAggregateDeviceSubDeviceListKey] == nil)
        check("Core Audio errors as four-character codes", AudioTap.fourCC(1852797029) == "nope"
              && AudioTap.describe(1852797029) == "'nope' (1852797029)" && AudioTap.fourCC(-50) == nil)
    }
}
