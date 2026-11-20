import Foundation

/// Your playlists in the Music app, for the playlist editor. Big lists take Music a second or two to
/// answer, so these scripts run in `osascript` off the main thread (macOS counts it as Retroamp for
/// the Automation permission). Playback commands go through `PlayerBridge`.
enum MusicLibrary {
    struct ScriptError: LocalizedError {
        let code: Int
        let message: String

        var errorDescription: String? {
            switch code {
            case -1743: return "Retroamp isn't allowed to control Music. Allow it in System Settings > Privacy & Security > Automation."
            case -600: return "Music isn't running."
            default: return message
            }
        }
    }

    /// Music's persistent IDs are 16 hex digits; anything else can't go into a script.
    static func sanitized(_ id: String) -> String? {
        let hex = id.filter(\.isHexDigit)
        return hex.count == 16 && hex.count == id.count ? hex : nil
    }

    // Fields and rows are separated by ASCII unit and record separators, which names can't hold.
    private static let fs = "\u{1F}", rs = "\u{1E}"
    private static let separators = "set FS to character id 31\nset RS to character id 30\n"

    /// User playlists and the library itself, without folders, in Music's order.
    static func playlists() async throws -> [PlaylistEntry] {
        let out = try await run(separators + """
        tell application "Music"
            set ids to persistent ID of every user playlist
            set nms to name of every user playlist
            set kinds to special kind of every user playlist
            set durs to duration of every user playlist
            set out to {}
            repeat with i from 1 to count of ids
                set end of out to (item i of ids) & FS & ((item i of kinds) as text) & FS & (round (item i of durs)) & FS & (item i of nms)
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """)
        return rows(out).compactMap { f in
            guard f.count >= 4, f[1] == "none" || f[1] == "Music" else { return nil }
            return PlaylistEntry(kind: .playlist(owned: true), title: f[3...].joined(separator: fs),
                                 duration: Double(f[2]).flatMap { $0 > 0 ? $0 : nil }, uri: f[0], id: f[0])
        }
    }

    /// A playlist's tracks (at most `limit`), or those of the one Music is playing from when `id`
    /// is nil. Returns the playlist's ID and name too.
    static func tracks(playlist id: String?, limit: Int) async throws -> (id: String, name: String, tracks: [PlaylistEntry]) {
        var ref = "current playlist"
        if let id {
            guard let safe = sanitized(id) else { throw ScriptError(code: 0, message: "Not a Music playlist.") }
            ref = "(first playlist whose persistent ID is \"\(safe)\")"
        }
        let out = try await run(separators + """
        tell application "Music"
            set p to \(ref)
            set head to (persistent ID of p) & FS & (name of p)
            set n to count of tracks of p
            if n > \(limit) then set n to \(limit)
            set ids to {}
            if n > 0 then
                set ids to persistent ID of tracks 1 thru n of p
                set nms to name of tracks 1 thru n of p
                set ars to artist of tracks 1 thru n of p
                set durs to duration of tracks 1 thru n of p
            end if
        end tell
        set out to {head}
        repeat with i from 1 to count of ids
            set a to item i of ars
            if a is missing value then set a to ""
            set d to 0
            try
                set d to round (item i of durs)
            end try
            set end of out to (item i of ids) & FS & d & FS & a & FS & (item i of nms)
        end repeat
        set AppleScript's text item delimiters to RS
        return out as text
        """)
        var all = rows(out)
        guard !all.isEmpty, all[0].count >= 2 else { throw ScriptError(code: 0, message: "Music gave no answer.") }
        let head = all.removeFirst()
        let tracks = all.compactMap { f -> PlaylistEntry? in
            guard f.count >= 4 else { return nil }
            let name = f[3...].joined(separator: fs)
            return PlaylistEntry(kind: .track, title: f[2].isEmpty ? name : "\(f[2]) - \(name)",
                                 duration: Double(f[1]).flatMap { $0 > 0 ? $0 : nil }, uri: f[0])
        }
        return (head[0], head[1...].joined(separator: fs), tracks)
    }

    private static func rows(_ text: String) -> [[String]] {
        text.components(separatedBy: rs).filter { !$0.isEmpty }.map { $0.components(separatedBy: fs) }
    }

    /// Runs a script in `osascript` and returns what it printed, without the final newline.
    static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    // "…: execution error: Music got an error: Can't get current playlist. (-1728)"
                    let match = (try? Regex(#"\((-?\d+)\)\s*$"#)).flatMap { errText.firstMatch(of: $0) }
                    let code = match.flatMap { $0.output[1].substring }.flatMap { Int($0) } ?? 0
                    let message = errText.components(separatedBy: "error: ").last?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"
                    cont.resume(throwing: ScriptError(code: code, message: message))
                    return
                }
                var text = String(decoding: data, as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }
                cont.resume(returning: text)
            }
        }
    }
}
