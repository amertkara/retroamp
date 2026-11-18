import AppKit
import CryptoKit
import Foundation
import Security

/// Web API failures, phrased for the playlist editor.
enum WebAPIError: LocalizedError {
    case notConnected
    case signIn(String)             // the sign-in is missing, failed or was revoked: connect again
    case forbidden(String)
    case http(Int, String)
    case rateLimited
    case badResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Spotify isn't connected."
        case .signIn(let why): return why
        case .forbidden(let why): return why.isEmpty ? "Spotify refused the request (403)." : "Spotify: \(why)"
        case .http(let code, let why): return why.isEmpty ? "Spotify returned error \(code)." : "Spotify: \(why) (\(code))"
        case .rateLimited: return "Spotify is rate limiting Retroamp. Try again in a minute."
        case .badResponse: return "Spotify sent an unexpected response."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Spotify's Web API: queue, playlists and Liked Songs, which the desktop app's AppleScript lacks.
///
/// Sign-in uses the authorization code flow with PKCE, so there is no client secret. Spotify
/// requires every app to have its own Client ID, so the user registers one on the developer
/// dashboard. The refresh token is kept in the login keychain; access tokens only in memory.
@MainActor
final class SpotifyWebAPI {
    static let port: UInt16 = 43275
    /// Spotify only allows plain HTTP redirects to loopback IP literals ("localhost" is rejected).
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    static let scopes = ["user-read-playback-state", "user-read-currently-playing", "user-modify-playback-state",
                         "playlist-read-private", "playlist-read-collaborative", "user-library-read"]

    enum Keys { static let clientID = "spotifyClientID", connected = "spotifyConnected" }

    private(set) var clientID: String?
    private(set) var user: (id: String, name: String)?
    private(set) var isConnecting = false
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshToken: String?
    private var refreshTokenLoaded = false
    private var refreshTask: Task<String, Error>?
    private var server: LoopbackServer?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    init() {
        clientID = UserDefaults.standard.string(forKey: Keys.clientID)
    }

    /// A sign-in is stored (checked without touching the Keychain).
    var isConnected: Bool { clientID != nil && UserDefaults.standard.bool(forKey: Keys.connected) }

    static func isValidClientID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    // MARK: Sign-in

    /// Opens Spotify's consent page in the browser and waits for its redirect to 127.0.0.1.
    func connect(clientID newID: String) async throws {
        cancelConnect()
        let verifier = PKCE.randomString(64)
        let state = PKCE.randomString(32)
        let params = [
            "response_type": "code", "client_id": newID, "scope": Self.scopes.joined(separator: " "),
            "redirect_uri": Self.redirectURI, "code_challenge_method": "S256",
            "code_challenge": PKCE.challenge(for: verifier), "state": state,
        ]
        guard let url = URL(string: "https://accounts.spotify.com/authorize?" + Self.formEncode(params)) else {
            throw WebAPIError.badResponse
        }
        let server = LoopbackServer(port: Self.port)
        try server.start()
        self.server = server
        isConnecting = true
        defer {
            isConnecting = false
            if self.server === server { self.server = nil }
        }
        NSWorkspace.shared.open(url)

        switch await server.waitForCallback(state: state, timeout: 300) {
        case .cancelled: throw WebAPIError.cancelled
        case .timedOut: throw WebAPIError.signIn("The Spotify sign-in timed out.")
        case .denied(let why):
            throw WebAPIError.signIn(why == "access_denied" ? "The Spotify sign-in was declined." : "Spotify sign-in failed: \(why)")
        case .code(let code):
            let json = try await tokenRequest([
                "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                "client_id": newID, "code_verifier": verifier,
            ])
            if let old = clientID, old != newID { Keychain.delete(account: old) }
            clientID = newID
            UserDefaults.standard.set(newID, forKey: Keys.clientID)
            refreshToken = nil
            refreshTokenLoaded = true
            user = nil
            _ = try await store(json)
            guard refreshToken != nil else { throw WebAPIError.badResponse }
            _ = try await me()
        }
    }

    func cancelConnect() { server?.cancel() }

    func disconnect() {
        cancelConnect()
        if let id = clientID { Keychain.delete(account: id) }
        forgetSignIn()
    }

    private func forgetSignIn() {
        accessToken = nil
        refreshToken = nil
        refreshTokenLoaded = true
        user = nil
        UserDefaults.standard.set(false, forKey: Keys.connected)
    }

    /// A valid access token, refreshed shortly before it expires (one refresh at a time).
    private func token() async throws -> String {
        if let t = accessToken, accessExpiry.timeIntervalSinceNow > 60 { return t }
        if let running = refreshTask { return try await running.value }
        let task = Task { @MainActor in try await self.refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        guard let id = clientID, isConnected else { throw WebAPIError.notConnected }
        if !refreshTokenLoaded {
            // Off the main thread: after a rebuild, macOS may ask whether Retroamp can use the item.
            let (value, status) = await Task.detached { Keychain.read(account: id) }.value
            if !refreshTokenLoaded, clientID == id {  // unless a new sign-in arrived meanwhile
                if value == nil, status != errSecItemNotFound {
                    // Denied (e.g. the Keychain prompt was dismissed): keep the item for next time.
                    throw WebAPIError.signIn("Retroamp couldn't read its Spotify sign-in from the Keychain (error \(status)).")
                }
                refreshToken = value
                refreshTokenLoaded = true
            }
        }
        guard let rt = refreshToken, clientID == id, isConnected else {
            if isConnected { forgetSignIn() }
            throw WebAPIError.signIn("The Spotify sign-in is missing from the Keychain.")
        }
        let json = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": rt, "client_id": id])
        return try await store(json)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? ""
            let why = (json["error_description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? code
            if code == "invalid_grant" || code == "invalid_client" {
                if form["grant_type"] == "refresh_token" {
                    if let id = clientID { Keychain.delete(account: id) }
                    forgetSignIn()
                }
                throw WebAPIError.signIn("Spotify rejected the sign-in (\(why)).")
            }
            throw WebAPIError.http(status, why)
        }
        return json
    }

    /// Keeps a token response. With PKCE, Spotify may rotate the refresh token, so store the new one.
    private func store(_ json: [String: Any]) async throws -> String {
        guard let t = json["access_token"] as? String, !t.isEmpty else { throw WebAPIError.badResponse }
        accessToken = t
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        if let rt = json["refresh_token"] as? String, !rt.isEmpty, rt != refreshToken, let id = clientID {
            refreshToken = rt
            refreshTokenLoaded = true
            UserDefaults.standard.set(true, forKey: Keys.connected)
            let saved = await Task.detached { Keychain.write(rt, account: id) }.value
            if !saved { NSLog("Retroamp: couldn't save the Spotify sign-in to the Keychain") }
        }
        return t
    }

    // MARK: Requests

    private func request(_ method: String, _ url: URL, json body: Data? = nil, retried: Bool = false) async throws -> (Int, Data) {
        let token = try await token()
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            req.httpBody = Data()  // an explicit Content-Length: 0
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 200..<300:
            return (status, data)
        case 401 where !retried:
            accessToken = nil
            return try await request(method, url, json: body, retried: true)
        case 429 where !retried:
            let wait = min(30, max(1, Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            return try await request(method, url, json: body, retried: true)
        case 429:
            throw WebAPIError.rateLimited
        case 403:
            throw WebAPIError.forbidden(Self.errorMessage(data))
        default:
            throw WebAPIError.http(status, Self.errorMessage(data))
        }
    }

    /// GET a path under /v1, or a `next` URL from a previous page.
    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        let raw: String
        if path.hasPrefix("https://") {
            guard path.hasPrefix("https://api.spotify.com/v1/") else { throw WebAPIError.badResponse }
            raw = path
        } else {
            raw = "https://api.spotify.com/v1" + path + (query.isEmpty ? "" : "?" + Self.formEncode(query))
        }
        guard let url = URL(string: raw) else { throw WebAPIError.badResponse }
        let (status, data) = try await request("GET", url)
        if status == 204 || data.isEmpty { return [:] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw WebAPIError.badResponse }
        return json
    }

    static func errorMessage(_ data: Data) -> String {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if let e = j["error"] as? [String: Any] { return e["message"] as? String ?? "" }
        return j["error_description"] as? String ?? j["error"] as? String ?? ""
    }

    static func formEncode(_ form: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }

    // MARK: Endpoints

    struct Page {
        var entries: [PlaylistEntry]
        var next: String?
        var total: Int
    }

    func me() async throws -> (id: String, name: String) {
        if let u = user { return u }
        let j = try await get("/me")
        guard let id = j["id"] as? String, !id.isEmpty else { throw WebAPIError.badResponse }
        let u = (id: id, name: (j["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        user = u
        return u
    }

    /// The playing item followed by what's queued (Spotify returns up to about 20).
    func queue() async throws -> (current: PlaylistEntry?, upNext: [PlaylistEntry]) {
        let j = try await get("/me/player/queue")
        let current = (j["currently_playing"] as? [String: Any]).flatMap(Self.entry(fromItem:))
        let upNext = (j["queue"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Self.entry(fromItem:)) }
        return (current, upNext)
    }

    func playlists(next: String?) async throws -> Page {
        let me = try await me()
        let j: [String: Any]
        if let next { j = try await get(next) } else { j = try await get("/me/playlists", ["limit": "50"]) }
        var out: [PlaylistEntry] = []
        for case let p as [String: Any] in j["items"] as? [Any] ?? [] {
            guard let id = p["id"] as? String, let name = p["name"] as? String else { continue }
            let owner = (p["owner"] as? [String: Any])?["id"] as? String
            let collaborative = p["collaborative"] as? Bool ?? false
            // Renamed from "tracks" to "items" in the February 2026 API changes.
            let counts = (p["items"] as? [String: Any]) ?? (p["tracks"] as? [String: Any])
            out.append(PlaylistEntry(kind: .playlist(owned: owner == me.id || collaborative), title: name,
                                     count: (counts?["total"] as? NSNumber)?.intValue,
                                     uri: p["uri"] as? String ?? "spotify:playlist:\(id)", id: id))
        }
        return Page(entries: out, next: j["next"] as? String, total: (j["total"] as? NSNumber)?.intValue ?? out.count)
    }

    /// Tracks of a playlist the user owns or collaborates on (Spotify refuses others since 2026).
    func playlistItems(id: String, next: String?) async throws -> Page {
        let j: [String: Any]
        if let next { j = try await get(next) } else {
            let safe = String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
            j = try await get("/playlists/\(safe)/items", ["limit": "50", "additional_types": "track,episode"])
        }
        return Self.trackPage(j)
    }

    func likedTracks(next: String?) async throws -> Page {
        let j: [String: Any]
        if let next { j = try await get(next) } else { j = try await get("/me/tracks", ["limit": "50"]) }
        return Self.trackPage(j)
    }

    func likedCount() async throws -> Int? {
        (try await get("/me/tracks", ["limit": "1"])["total"] as? NSNumber)?.intValue
    }

    /// Adds a track or episode to the end of the queue (Premium only).
    func addToQueue(_ uri: String) async throws {
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/queue?" + Self.formEncode(["uri": uri])) else {
            throw WebAPIError.badResponse
        }
        _ = try await request("POST", url)
    }

    /// Starts playback (Premium only) with `{"context_uri", "offset"}` or `{"uris"}`, on the active
    /// device or the given one. Spotify answers 204 once it has passed the command on, and 404
    /// when no device is active. Unlike AppleScript, this doesn't bring Spotify's window forward.
    func startPlayback(_ body: [String: Any], deviceID: String? = nil) async throws {
        var raw = "https://api.spotify.com/v1/me/player/play"
        if let deviceID { raw += "?" + Self.formEncode(["device_id": deviceID]) }
        guard let url = URL(string: raw), JSONSerialization.isValidJSONObject(body) else { throw WebAPIError.badResponse }
        _ = try await request("PUT", url, json: try JSONSerialization.data(withJSONObject: body))
    }

    struct Device: Equatable {
        var id: String
        var name: String
        var type: String            // "Computer", "Smartphone", "Speaker"…
        var isActive: Bool
    }

    /// Spotify Connect devices that can play right now.
    func devices() async throws -> [Device] { Self.devices(from: try await get("/me/player/devices")) }

    /// The URI of what Spotify is playing from (a playlist, an album, DJ…); nil if nothing is.
    func playingContextURI() async throws -> String? { Self.contextURI(from: try await get("/me/player")) }

    static func contextURI(from player: [String: Any]) -> String? {
        (player["context"] as? [String: Any])?["uri"] as? String
    }

    // MARK: Parsing

    static func devices(from j: [String: Any]) -> [Device] {
        (j["devices"] as? [Any] ?? []).compactMap {
            guard let d = $0 as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }  // restricted ones have none
            return Device(id: id, name: d["name"] as? String ?? "", type: d["type"] as? String ?? "",
                          isActive: d["is_active"] as? Bool ?? false)
        }
    }

    static func trackPage(_ j: [String: Any]) -> Page {
        var out: [PlaylistEntry] = []
        for case let row as [String: Any] in j["items"] as? [Any] ?? [] {
            // Playlist rows call it "item" since February 2026 ("track" before); saved tracks use "track".
            guard let t = (row["item"] as? [String: Any]) ?? (row["track"] as? [String: Any]),
                  var e = entry(fromItem: t) else { continue }
            if row["is_local"] as? Bool == true { e.kind = .local }
            out.append(e)
        }
        return Page(entries: out, next: j["next"] as? String, total: (j["total"] as? NSNumber)?.intValue ?? out.count)
    }

    /// "Artist, Artist - Title" for tracks, "Show - Episode" for podcast episodes.
    static func entry(fromItem t: [String: Any]) -> PlaylistEntry? {
        guard let name = t["name"] as? String else { return nil }
        let uri = t["uri"] as? String
        var title = name
        let artists = (t["artists"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
            .filter { !$0.isEmpty }
        if !artists.isEmpty {
            title = artists.joined(separator: ", ") + " - " + name
        } else if let show = (t["show"] as? [String: Any])?["name"] as? String, !show.isEmpty {
            title = show + " - " + name
        }
        let local = t["is_local"] as? Bool == true || uri?.hasPrefix("spotify:local:") == true
        let ms = (t["duration_ms"] as? NSNumber)?.doubleValue
        return PlaylistEntry(kind: local ? .local : .track, title: title, duration: ms.map { $0 / 1000 }, uri: uri)
    }
}

// MARK: - PKCE

enum PKCE {
    /// 64 URL-safe characters, so each random byte maps without bias.
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func randomString(_ length: Int) -> String {
        var rng = SystemRandomNumberGenerator()  // arc4random: cryptographically secure on Apple platforms
        return String((0..<length).map { _ in alphabet[Int(rng.next() & 63)] })
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

/// Generic passwords in the login keychain. Ad-hoc signed builds are identified by their hash, so
/// macOS asks once for access after each rebuild.
enum Keychain {
    static let service = "local.retroamp.spotify"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> (value: String?, status: OSStatus) {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Retroamp Spotify sign-in"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

// MARK: - Loopback redirect receiver

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    enum Outcome: Equatable { case code(String), denied(String), timedOut, cancelled }

    let port: UInt16
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    init(port: UInt16) { self.port = port }
    deinit { closeSocket() }

    func start() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw WebAPIError.signIn("Couldn't open a local socket (\(String(cString: strerror(errno)))).") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 8) == 0 else {
            let why = String(cString: strerror(errno))
            close(s)
            throw WebAPIError.signIn("Port \(port) on 127.0.0.1 is in use (\(why)). Close the other app using it and try again.")
        }
        lock.lock(); fd = s; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func closeSocket() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    func waitForCallback(state: String, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            Thread.detachNewThread { [self] in
                done.resume(returning: self.serve(state: state, deadline: Date().addingTimeInterval(timeout)))
            }
        }
    }

    /// Blocks until /callback arrives with the expected state, the deadline passes or cancel() is called.
    /// Connections are served side by side, so a browser's idle pre-connect can't hold up the real one.
    func serve(state: String, deadline: Date) -> Outcome {
        defer { closeSocket() }
        lock.lock(); let listener = fd; lock.unlock()
        guard listener >= 0 else { return .cancelled }
        var clients: [(fd: Int32, data: Data, since: Date)] = []
        defer { for c in clients { close(c.fd) } }
        var buf = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while true {
            if isCancelled { return .cancelled }
            if Date() > deadline { return .timedOut }
            var pfds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
                + clients.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&pfds, nfds_t(pfds.count), 250)
            var open: [(fd: Int32, data: Data, since: Date)] = []
            for (i, var c) in clients.enumerated() {
                var finished = Date().timeIntervalSince(c.since) > 10  // idle or trickling: drop it
                if !finished, ready > 0, pfds[i + 1].revents != 0 {
                    let n = recv(c.fd, &buf, buf.count, 0)
                    if n <= 0 { finished = true } else { c.data.append(buf, count: n) }
                    if !finished, c.data.range(of: end) != nil || c.data.count >= 16384 {
                        finished = true
                        if let outcome = handle(c.fd, c.data, state: state) {
                            close(c.fd)
                            for other in open + clients[(i + 1)...] { close(other.fd) }
                            clients = []
                            return outcome
                        }
                    }
                }
                if finished { close(c.fd) } else { open.append(c) }
            }
            clients = open
            if ready > 0, pfds[0].revents & Int16(POLLIN) != 0 {
                let c = accept(listener, nil, nil)
                if c >= 0 {
                    if clients.count >= 16 { close(c) } else {
                        var one: Int32 = 1
                        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                        var tv = timeval(tv_sec: 2, tv_usec: 0)  // bounds the response write
                        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                        clients.append((c, Data(), Date()))
                    }
                }
            }
        }
    }

    /// Answers one request. Returns an outcome for a /callback carrying the expected state.
    private func handle(_ client: Int32, _ data: Data, state: String) -> Outcome? {
        guard let head = String(data: data, encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/"),
              let comps = URLComponents(string: "http://127.0.0.1" + parts[1]), comps.path == "/callback" else {
            respond(client, "404 Not Found", "Not found", "This address only finishes connecting Retroamp to Spotify.")
            return nil
        }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        guard q["state"] == state else {
            respond(client, "400 Bad Request", "Sign-in not recognised",
                    "This sign-in doesn't belong to the current Retroamp request. Start connecting again from Retroamp.")
            return nil
        }
        if let code = q["code"], !code.isEmpty {
            respond(client, "200 OK", "Signed in to Spotify", "You can close this tab and go back to Retroamp.")
            return .code(code)
        }
        let why = q["error"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
        respond(client, "200 OK", "Spotify sign-in didn't finish",
                why == "access_denied" ? "Access was declined. You can close this tab." : "Spotify said: \(why)")
        return .denied(why)
    }

    private func respond(_ client: Int32, _ status: String, _ title: String, _ message: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>
        body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#1b1f27;
        color:#d8dee9;font:15px -apple-system,Helvetica,sans-serif}h1{color:#39ff88;font-size:20px}
        </style></head><body><div><h1>\(esc(title))</h1><p>\(esc(message))</p></div></body></html>
        """
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
            + "Connection: close\r\n\r\n"
        let all = Array(head.utf8) + bytes
        var sent = 0
        while sent < all.count {
            let n = all[sent...].withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            sent += n
        }
    }
}
