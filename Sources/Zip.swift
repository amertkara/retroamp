import Compression
import Foundation

/// Minimal read-only ZIP reader (stored and deflated entries, no ZIP64 or encryption). Enough for
/// classic .wsz skins, and nothing is ever written to disk.
struct ZipArchive {
    struct Entry {
        let name: String
        fileprivate let flags: Int, method: Int, compressedSize: Int, size: Int, offset: Int
    }

    static let maxArchiveSize = 64 << 20
    static let maxEntrySize = 32 << 20

    let entries: [Entry]
    private let bytes: [UInt8]

    init?(_ data: Data) {
        guard data.count <= ZipArchive.maxArchiveSize else { return nil }
        bytes = [UInt8](data)
        guard let list = ZipArchive.centralDirectory(bytes) else { return nil }
        entries = list
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }

    private static func centralDirectory(_ b: [UInt8]) -> [Entry]? {
        guard b.count >= 22 else { return nil }
        // The end-of-central-directory record sits at the end, possibly followed by a comment.
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 0xFFFF) {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        var p = u32(b, eocd + 16)
        var out: [Entry] = []
        for _ in 0..<u16(b, eocd + 10) {
            guard p >= 0, p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { return nil }
            let nameLength = u16(b, p + 28)
            guard p + 46 + nameLength <= b.count else { return nil }
            let raw = Array(b[(p + 46)..<(p + 46 + nameLength)])
            let name = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
            out.append(Entry(name: name, flags: u16(b, p + 8), method: u16(b, p + 10),
                             compressedSize: u32(b, p + 20), size: u32(b, p + 24), offset: u32(b, p + 42)))
            p += 46 + nameLength + u16(b, p + 30) + u16(b, p + 32)
        }
        return out
    }

    /// The entry's contents, or nil when it is encrypted, uses another method, is corrupt or too big.
    func contents(of e: Entry) -> Data? {
        let b = bytes
        guard e.flags & 1 == 0, e.size <= ZipArchive.maxEntrySize, e.offset + 30 <= b.count,
              ZipArchive.u32(b, e.offset) == 0x0403_4B50 else { return nil }
        let start = e.offset + 30 + ZipArchive.u16(b, e.offset + 26) + ZipArchive.u16(b, e.offset + 28)
        guard start + e.compressedSize <= b.count else { return nil }

        switch e.method {
        case 0:
            guard e.compressedSize == e.size else { return nil }
            return Data(b[start..<(start + e.size)])
        case 8:
            guard e.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            // COMPRESSION_ZLIB is raw DEFLATE (no zlib header), which is exactly what ZIP stores.
            let written = b.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress! + start,
                                              e.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            return written == e.size ? Data(out) : nil
        default:
            return nil
        }
    }
}
