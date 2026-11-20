import AppKit
import CryptoKit

/// The Winamp Skin Museum (skins.webamp.org): lists and searches skins through its public GraphQL
/// API, the same one the museum's site uses. Screenshots and skins are fetched only when shown or
/// chosen, and kept on disk, so each one is downloaded once.
enum SkinMuseum {
    struct Item: Equatable {
        let md5: String
        let filename: String
        let screenshot: URL
        let download: URL

        /// "Some Skin" for "Some_Skin.wsz".
        var name: String {
            let base = (filename as NSString).deletingPathExtension
            return base.replacingOccurrences(of: "_", with: " ")
        }
    }

    static let api = URL(string: "https://api.webamp.org/graphql")!
    static let site = URL(string: "https://skins.webamp.org/")!
    static let pageSize = 48

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Retroamp/0.2 (+https://github.com/amertkara/retroamp)"]
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    enum Failure: LocalizedError {
        case http(Int), badAnswer, graphQL(String), tooBig, corrupt
        var errorDescription: String? {
            switch self {
            case .http(let code): return "The museum answered HTTP \(code)."
            case .badAnswer: return "The museum's answer wasn't understood."
            case .graphQL(let message): return "The museum said: \(message)"
            case .tooBig: return "The skin is larger than a classic skin can be."
            case .corrupt: return "The download doesn't match the museum's checksum."
            }
        }
    }

    // MARK: Listing

    /// One page of skins: the museum's own order (its most-loved first) or, with a query, its search.
    /// NSFW skins are left out, as on the museum's front page. `total` is known only without a query.
    static func page(query: String, offset: Int) async throws -> (items: [Item], total: Int?, more: Bool) {
        let fields = "md5 filename screenshot_url download_url nsfw"
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        if q.isEmpty {
            body = ["query": "query($first: Int, $offset: Int) { skins(first: $first, offset: $offset, sort: MUSEUM) { count nodes { \(fields) } } }",
                    "variables": ["first": pageSize, "offset": offset]]
        } else {
            body = ["query": "query($q: String!, $first: Int!, $offset: Int!) { search_classic_skins(query: $q, first: $first, offset: $offset, nsfw: false) { \(fields) } }",
                    "variables": ["q": q, "first": pageSize, "offset": offset]]
        }
        var req = URLRequest(url: api)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.http(code) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badAnswer }
        guard let d = root["data"] as? [String: Any] else {
            let first = (root["errors"] as? [[String: Any]])?.first?["message"] as? String
            throw first.map(Failure.graphQL) ?? Failure.badAnswer
        }
        let nodes: [[String: Any]]
        var total: Int?
        if let skins = d["skins"] as? [String: Any] {
            nodes = skins["nodes"] as? [[String: Any]] ?? []
            total = skins["count"] as? Int
        } else {
            nodes = d["search_classic_skins"] as? [[String: Any]] ?? []
        }
        let items = nodes.compactMap(item(from:))
        return (items, total, nodes.count == pageSize)
    }

    static func item(from n: [String: Any]) -> Item? {
        guard n["nsfw"] as? Bool != true,
              let md5 = n["md5"] as? String, md5.count == 32, md5.allSatisfy(\.isHexDigit),
              let shot = (n["screenshot_url"] as? String).flatMap(URL.init(string:)),
              let dl = (n["download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Item(md5: md5.lowercased(), filename: n["filename"] as? String ?? md5, screenshot: shot, download: dl)
    }

    // MARK: Files

    /// Downloaded skins, next to the classic base skin.
    static var skinsFolder: URL { ClassicSkin.fileURL.deletingLastPathComponent().appendingPathComponent("Museum") }

    private static var thumbnailFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.retroamp/Museum Screenshots")
    }

    /// The skin's .wsz on disk, downloaded the first time and checked against its MD5 (the museum
    /// names every skin by the MD5 of its file).
    static func skinFile(_ item: Item) async throws -> URL {
        let file = skinsFolder.appendingPathComponent("\(item.md5).wsz")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let (data, response) = try await session.data(from: item.download)
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw Failure.http(code) }
        guard data.count <= ZipArchive.maxArchiveSize else { throw Failure.tooBig }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard md5 == item.md5 else { throw Failure.corrupt }
        try FileManager.default.createDirectory(at: skinsFolder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    private static let thumbnails = NSCache<NSString, NSImage>()

    /// The main window from the museum's screenshot (which shows Webamp's three windows stacked).
    static func cachedThumbnail(_ item: Item) -> NSImage? { thumbnails.object(forKey: item.md5 as NSString) }

    static func thumbnail(_ item: Item) async -> NSImage? {
        if let hit = cachedThumbnail(item) { return hit }
        let file = thumbnailFolder.appendingPathComponent("\(item.md5).png")
        var data = try? Data(contentsOf: file)
        if data == nil, let (fetched, response) = try? await session.data(from: item.screenshot),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        }
        guard let data, let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        let h = min(cg.height, Layout.size.h * cg.width / Layout.size.w)
        guard let main = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: h)) else { return nil }
        let img = NSImage(cgImage: main, size: NSSize(width: main.width, height: main.height))
        thumbnails.setObject(img, forKey: item.md5 as NSString)
        return img
    }
}
