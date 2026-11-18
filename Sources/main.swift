import AppKit

// Headless helpers used by build.sh and for checking skins without launching the UI:
//   Retroamp --snapshot out.png [--skin x.wsz] [--scale 1|2] [--state playing|paused|stopped]
//            [--vis bars|osc|off] [--press play] [--remaining] [--inactive] [--text "..."]
//            [--with-playlist]   (adds the playlist editor below; see Snapshot.playlistState for options)
//   Retroamp --playlist-snapshot out.png [--skin x.wsz] [--scale n] [--size cols,rows] [--menu add] ...
//   Retroamp --dump-sheets dir [--skin x.wsz]   (writes a skin's sprite sheets as PNGs)
//   Retroamp --make-icon out.icns
//   Retroamp --selftest   (sign-in listener, PKCE and Web API parsing; no network or account needed)
if let out = Snapshot.arg("--snapshot") { exit(Snapshot.render(to: out)) }
if let out = Snapshot.arg("--playlist-snapshot") { exit(Snapshot.renderPlaylist(to: out)) }
if let dir = Snapshot.arg("--dump-sheets") { exit(Snapshot.dumpSheets(to: dir)) }
if let out = Snapshot.arg("--make-icon") { exit(Snapshot.makeIcon(to: out)) }
if Snapshot.flag("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
