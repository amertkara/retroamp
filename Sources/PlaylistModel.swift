import Foundation

/// What double-clicking an informational row does.
enum InfoAction: Equatable { case none, connect, cancelConnect, retry, playContext(String), playDJ, showLibrary, showQueue }

/// One row of the playlist editor.
struct PlaylistEntry: Equatable {
    enum Kind: Equatable {
        case track                          // a track or podcast episode
        case local                          // a local file inside a playlist (can't be started from here)
        case playlist(owned: Bool)
        case liked
        case dj                             // Spotify's AI DJ
        case info(InfoAction)
    }

    var kind: Kind
    var title: String
    var duration: Double? = nil             // seconds
    var count: Int? = nil                   // tracks in a playlist
    var uri: String? = nil
    var id: String? = nil                   // playlist ID

    static func info(_ text: String, _ action: InfoAction = .none) -> PlaylistEntry {
        PlaylistEntry(kind: .info(action), title: text)
    }

    /// Right-hand column: the track length, or the size of a playlist.
    var durationText: String {
        if let d = duration { return PlaylistEntry.timeString(d) }
        if let n = count { return "\(n)" }
        return ""
    }

    var isTrack: Bool { kind == .track || kind == .local }

    var isInfo: Bool { if case .info = kind { return true } else { return false } }

    /// Shown until Spotify's Web API is connected.
    static let notConnected: [PlaylistEntry] = [
        .info("Connect Spotify to see your queue and playlists."),
        .info("Double-click here to connect\u{2026}", .connect),
        .info(""),
        .info("You'll need the Client ID of a Spotify developer app."),
        .info("Playback controls work without connecting."),
        .info(""),
        .info("Double-click here to start Spotify DJ.", .playDJ),
    ]

    /// The DJ row in Your Playlists.
    static let dj = PlaylistEntry(kind: .dj, title: "Spotify DJ", uri: SpotifyLink.djURI)

    /// "3:45", "12:05" (minutes are not capped, like the classic playlist).
    static func timeString(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    /// Running-time format: minutes and seconds, with hours once it gets long.
    static func longTimeString(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        if t >= 3600 { return "\(t / 3600):" + String(format: "%02d:%02d", (t / 60) % 60, t % 60) }
        return timeString(Double(t))
    }
}

/// Which list the playlist editor shows.
enum PlaylistSource: Equatable {
    case queue
    case library                                    // your playlists
    case liked                                      // Liked Songs
    case playlist(id: String, name: String, uri: String)

    var label: String {
        switch self {
        case .queue: return "QUEUE"
        case .library: return "YOUR PLAYLISTS"
        case .liked: return "LIKED SONGS"
        case .playlist(_, let name, _): return name.uppercased()
        }
    }

    var storageKey: String {
        switch self {
        case .queue: return "queue"
        case .library, .playlist: return "library"
        case .liked: return "liked"
        }
    }

    init(storageKey: String?) {
        switch storageKey {
        case "library": self = .library
        case "liked": self = .liked
        default: self = .queue
        }
    }
}
