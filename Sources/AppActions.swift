import AppKit
import UniformTypeIdentifiers

/// Button, slider, menu and dialog handling.
extension AppDelegate {
    // MARK: Buttons

    func clicked(_ c: Control) {
        let player = self.player
        let st = player.status
        switch c {
        case .play:
            if !playerAppRunning { player.launch(thenPlay: true) }
            else if st.state == .playing { player.seek(to: 0) }  // classic: Play restarts the track
            else { player.play() }
        case .pause:
            if st.state == .playing { player.pause() } else if st.state == .paused { player.play() }
        case .stop: player.stop()
        case .next: player.next()
        case .prev: player.previous()
        case .eject: if backend == .music { playlist.open(.library) } else { promptForLink() }
        case .shuffle:
            player.setShuffle(!st.shuffle)
            show("SHUFFLE: \(st.shuffle ? "OFF" : "ON")")
        case .repeatButton:
            player.setRepeat(!st.repeating)
            show("REPEAT: \(st.repeating ? "OFF" : "ON")")
        case .visualizer, .clutterV: cycleVisualizer()
        case .time: toggleTimeRemaining()
        case .options, .clutterO:
            let p = NSPoint(x: 10 * view.scale, y: view.bounds.height - 34 * view.scale)
            optionsMenu().popUp(positioning: nil, at: p, in: view)
        case .clutterA: toggleAlwaysOnTop()
        case .clutterI: copyTrackLink()
        case .clutterD: toggleDoubleSize()
        case .minimize: window.miniaturize(nil)
        case .close: NSApp.terminate(nil)
        case .shade: show("WINDOWSHADE MODE: COMING SOON")
        case .eq: show("EQUALIZER: NOT AVAILABLE FOR \(backend.displayName.uppercased())")
        case .pl: playlist.toggle()
        case .logo: if backend == .spotify { playDJ() }
        case .marquee, .volume, .balance, .position: break
        }
    }

    func togglePlayPause() {
        if playerAppRunning { player.playPause() } else { player.launch(thenPlay: true) }
    }

    func marqueeDoubleClicked() { showSpotify() }

    /// Switches between Spotify and Music.
    @objc func selectBackend(_ item: NSMenuItem) {
        let new: Backend = item.tag == 1 ? .music : .spotify
        guard new != backend else { return }
        backend = new
        savePreferences()
        playlist.backendChanged()
        pollTick()
        show("PLAYER: \(new.displayName.uppercased())", seconds: 2)
    }

    // MARK: Sliders

    func slider(_ c: Control, at p: CGPoint, phase: SliderPhase) {
        func fraction(_ g: (x: Int, thumb: Int, travel: Int)) -> Double {
            max(0, min(1, (Double(p.x) - Double(g.x) - Double(g.thumb) / 2) / Double(g.travel)))
        }
        switch c {
        case .volume:
            let vol = Int((fraction(Layout.volumeSlider) * 100).rounded())
            volumeOverride = phase == .ended ? nil : vol
            show("VOLUME: \(vol)%", seconds: 1)
            let now = Self.now
            if phase == .ended || now - lastVolumeSent > 0.08 {
                lastVolumeSent = now
                player.setVolume(vol)
            }
        case .balance:
            var b = Int((fraction(Layout.balanceSlider) * 200 - 100).rounded())
            if abs(b) < 15 { b = 0 }
            balance = phase == .ended ? 0 : b  // Spotify has no balance control; spring back
            show(phase == .ended ? "BALANCE: NOT AVAILABLE FOR SPOTIFY"
                 : b == 0 ? "BALANCE: CENTER" : "BALANCE: \(abs(b))% \(b < 0 ? "LEFT" : "RIGHT")", seconds: 1.2)
        case .position:
            let dur = player.status.duration
            guard player.status.running, dur > 0 else { positionOverride = nil; return }
            let f = fraction(Layout.positionSlider)
            if phase == .ended {
                positionOverride = nil
                player.seek(to: f * dur)
            } else {
                positionOverride = f
                show("SEEK TO: \(Self.format(f * dur))/\(Self.format(dur)) (\(Int(f * 100))%)", seconds: 1)
            }
        default: break
        }
    }

    func nudgeVolume(by delta: Int) {
        let v = max(0, min(100, (pendingVolume ?? player.status.volume) + delta))
        pendingVolume = v
        show("VOLUME: \(v)%", seconds: 1)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendPendingVolume), object: nil)
        perform(#selector(sendPendingVolume), with: nil, afterDelay: 0.06)
    }

    @objc func sendPendingVolume() {
        guard let v = pendingVolume else { return }
        player.setVolume(v)
        pendingVolume = nil
    }

    func seek(by seconds: Double) {
        let dur = player.status.duration
        guard player.status.running, dur > 0 else { return }
        let target = max(0, min(dur - 1, player.position + seconds))
        player.seek(to: target)
        show("SEEK TO: \(Self.format(target))/\(Self.format(dur))", seconds: 1)
    }

    // MARK: Toggles

    @objc func cycleVisualizer() {
        visMode = VisMode(rawValue: (visMode.rawValue + 1) % 3) ?? .bars
        show(["VISUALIZER: SPECTRUM", "VISUALIZER: OSCILLOSCOPE", "VISUALIZER: OFF"][visMode.rawValue])
        savePreferences()
    }

    @objc func selectVisualizer(_ item: NSMenuItem) {
        visMode = VisMode(rawValue: item.tag) ?? .bars
        savePreferences()
    }

    @objc func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        applyWindowLevel()
        savePreferences()
        show("ALWAYS ON TOP: \(alwaysOnTop ? "ON" : "OFF")")
    }

    /// Winamp's Double Size (⌘D, the "D" in the clutter bar): 2× and back to the original size.
    @objc func toggleDoubleSize() { setScale(scale == 2 ? 1 : 2) }

    @objc func toggleTimeRemaining() {
        timeRemaining.toggle()
        savePreferences()
        playlist?.redraw()
    }

    @objc func togglePlaylist() { playlist.toggle() }

    @objc func toggleSpotifyConnection() { playlist.toggleConnection() }

    // MARK: Links

    @objc func copyTrackLink() {
        guard let url = SpotifyLink.webURL(for: spotify.status.trackID) else { show("NOTHING TO COPY"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        show("TRACK LINK COPIED")
    }

    @objc func promptForLink() {
        let alert = NSAlert()
        alert.messageText = "Play a Spotify link"
        alert.informativeText = "Paste a link to a track, album, playlist, artist, show or episode (open.spotify.com/… or spotify:…)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://open.spotify.com/album/…"
        if let clip = NSPasteboard.general.string(forType: .string), SpotifyLink.uri(from: clip) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let uri = SpotifyLink.uri(from: field.stringValue) { play(uri: uri) } else { show("THAT IS NOT A SPOTIFY LINK", seconds: 3) }
    }

    func play(uri: String) {
        playback.start(.item(uri))
        show("LOADING \(uri.split(separator: ":").dropFirst().first?.uppercased() ?? "LINK")...", seconds: 2)
    }

    /// Spotify DJ: the Winamp logo, ⌘J and the DJ rows. Starts DJ, or gets different picks while it's on.
    @objc func playDJ() {
        playback.startDJ { [weak self] ok in
            if ok { self?.playlist?.refreshQueueIfShown() }
        }
    }

    /// Brings the player app forward (Spotify or Music).
    @objc func showSpotify() {
        playback.focus.disarm()  // asked for, so don't send it back
        player.activate()
    }

    func handleDrop(urls: [URL], strings: [String]) -> Bool {
        if let file = urls.first(where: \.isFileURL) {
            loadSkin(from: file)
            return true
        }
        for s in urls.map(\.absoluteString) + strings {
            if let uri = SpotifyLink.uri(from: s) { play(uri: uri); return true }
        }
        return false
    }

    // MARK: Skins

    func loadSkin(from url: URL) {
        do {
            applySkin(try Skin.load(from: url))
            skinChoice = .file
            UserDefaults.standard.set(url.path, forKey: Keys.skinPath)
            savePreferences()
            show("SKIN: \(skin.name)", seconds: 2.5)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't load \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func loadSkinFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a classic skin"
        panel.message = "Pick a .wsz file (or an unzipped skin folder). Thousands are at skins.webamp.org."
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { loadSkin(from: url) }
    }

    @objc func useBuiltInSkin() {
        skinChoice = .builtin
        applySkin(Skin.builtIn)
        savePreferences()
        show("SKIN: RETROAMP (BUILT-IN)", seconds: 2)
    }

    /// The Winamp 2.91 base skin, downloaded the first time it's used.
    @objc func useClassicSkin() {
        skinChoice = .classic
        savePreferences()
        if let s = ClassicSkin.loadCached() {
            applySkin(s)
            show("SKIN: \(s.name.uppercased())", seconds: 2)
        } else {
            downloadClassicSkin(announce: true)
        }
    }

    @objc func openSkinMuseum() { NSWorkspace.shared.open(URL(string: "https://skins.webamp.org/")!) }

    // MARK: Menus

    func optionsMenu() -> NSMenu {
        let m = NSMenu(title: "Retroamp")
        func add(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            m.addItem(item)
        }
        add("About Retroamp", #selector(showAbout))
        m.addItem(.separator())
        add("Playlist Editor", #selector(togglePlaylist), "e")
        m.items.last?.keyEquivalentModifierMask = [.option]  // Alt+E, as in the original
        add("Connect Spotify…", #selector(toggleSpotifyConnection))  // retitled in validateMenuItem
        m.addItem(.separator())

        let skins = NSMenu(title: "Skins")
        for (title, action, key) in [("Winamp Classic (Base 2.91)", #selector(useClassicSkin), ""),
                                     ("Retroamp Built-in", #selector(useBuiltInSkin), ""),
                                     ("Load Skin…", #selector(loadSkinFromPanel), "o"),
                                     ("Get More Skins…", #selector(openSkinMuseum), "")] {
            if action == #selector(loadSkinFromPanel) { skins.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            skins.addItem(item)
        }
        let skinsItem = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        skinsItem.submenu = skins
        m.addItem(skinsItem)
        m.addItem(.separator())
        add("Use Spotify", #selector(selectBackend(_:)), tag: 0)
        add("Use Apple Music", #selector(selectBackend(_:)), tag: 1)
        m.addItem(.separator())
        add("Play Spotify Link…", #selector(promptForLink), "l")
        add("Play Spotify DJ", #selector(playDJ), "j")
        add("Copy Track Link", #selector(copyTrackLink))
        add("Show Spotify", #selector(showSpotify))
        m.addItem(.separator())
        add("Always on Top", #selector(toggleAlwaysOnTop), "t")
        add("Double Size", #selector(toggleDoubleSize), "d")
        add("Show Time Remaining", #selector(toggleTimeRemaining))
        for (i, title) in ["Spectrum Analyzer", "Oscilloscope", "No Visualizer"].enumerated() {
            add(title, #selector(selectVisualizer(_:)), tag: i)
        }
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Retroamp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        return m
    }

    func showOptionsMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(optionsMenu(), with: event, for: view)
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = optionsMenu()
        main.addItem(appItem)

        // Standard Edit items: ⌘V in the "Play Spotify Link" field, and in the player ⌘C copies the
        // track link and ⌘V plays a copied link (PlayerView's copy:/paste:).
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAlwaysOnTop): item.state = alwaysOnTop ? .on : .off
        case #selector(toggleDoubleSize): item.state = scale == 2 ? .on : .off
        case #selector(toggleTimeRemaining): item.state = timeRemaining ? .on : .off
        case #selector(selectVisualizer(_:)): item.state = item.tag == visMode.rawValue ? .on : .off
        case #selector(useBuiltInSkin): item.state = skin.isBuiltIn ? .on : .off
        case #selector(useClassicSkin): item.state = skinChoice == .classic && !skin.isBuiltIn ? .on : .off
        case #selector(togglePlaylist): item.state = playlist?.isVisible == true ? .on : .off
        case #selector(selectBackend(_:)): item.state = item.tag == (backend == .music ? 1 : 0) ? .on : .off
        case #selector(toggleSpotifyConnection):
            item.title = playlist?.connectionMenuTitle ?? "Connect Spotify…"
            return backend == .spotify
        case #selector(promptForLink), #selector(playDJ): return backend == .spotify
        case #selector(showSpotify): item.title = "Show \(backend.appName)"
        case #selector(copyTrackLink): return backend == .spotify && !spotify.status.trackID.isEmpty
        default: break
        }
        return true
    }

    @objc func showAbout() {
        let credits = NSAttributedString(string: """
        A classic-style, skinnable mini player and playlist editor for the Spotify desktop app.
        The classic look is the Winamp Base Skin 2.91, downloaded on first launch from the Webamp \
        project (github.com/captbaritone/webamp). Skin geometry follows the classic skin format as \
        documented by Webamp (MIT). The queue and playlists come from the Spotify Web API.
        Not affiliated with Spotify or Winamp.
        """)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Retroamp", .applicationVersion: "0.2", .version: "", .credits: credits,
        ])
    }
}
