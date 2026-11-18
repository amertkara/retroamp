import CryptoKit
import Foundation

/// The classic Winamp 2.91 base skin, downloaded on first use from the Webamp project (pinned to a
/// commit and checked against a SHA-256) and kept in Application Support. Retroamp doesn't bundle it.
enum ClassicSkin {
    static let source = URL(string: "https://raw.githubusercontent.com/captbaritone/webamp/307a4650458ea6d51c7a6e696f079477b18b3cb7/packages/webamp/assets/skins/base-2.91.wsz")!
    static let sha256 = "cb2e5361a5208878855ae2c6c4a842df6cb71590b2c4405fe8776258c82e59bb"
    static let byteCount = 102_133
    static let displayName = "Winamp Base Skin 2.91"

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Retroamp/Skins/base-2.91.wsz")
    }

    static func isIntact(_ data: Data) -> Bool {
        data.count == byteCount && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// The downloaded copy, if present and unmodified.
    static func loadCached() -> Skin? {
        guard let data = try? Data(contentsOf: fileURL), isIntact(data) else { return nil }
        return try? Skin.load(from: fileURL, name: displayName)
    }

    static func download() async throws -> Skin {
        var req = URLRequest(url: source)
        req.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SkinError.unreadable("download failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var data = Data()
        data.reserveCapacity(byteCount)
        for try await b in bytes {
            data.append(b)
            if data.count > 1_048_576 { throw SkinError.unreadable("the download is larger than expected") }
        }
        guard isIntact(data) else { throw SkinError.unreadable("the download doesn't match the expected file") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return try Skin.load(from: fileURL, name: displayName)
    }
}
