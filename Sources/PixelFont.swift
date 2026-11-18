import Foundation

/// Original 5-pixel-tall font for the built-in skin, plus the classic TEXT.BMP cell layout
/// (31 columns × 3 rows of 5×6 cells) that every classic skin uses for the marquee.
enum PixelFont {
    private static let glyphs: [Character: String] = [
        "A": ".XX./X..X/XXXX/X..X/X..X", "B": "XXX./X..X/XXX./X..X/XXX.",
        "C": ".XXX/X.../X.../X.../.XXX", "D": "XXX./X..X/X..X/X..X/XXX.",
        "E": "XXXX/X.../XXX./X.../XXXX", "F": "XXXX/X.../XXX./X.../X...",
        "G": ".XXX/X.../X.XX/X..X/.XXX", "H": "X..X/X..X/XXXX/X..X/X..X",
        "I": "XXX/.X./.X./.X./XXX", "J": "..XX/...X/...X/X..X/.XX.",
        "K": "X..X/X.X./XX../X.X./X..X", "L": "X.../X.../X.../X.../XXXX",
        "M": "X...X/XX.XX/X.X.X/X...X/X...X", "N": "X..X/XX.X/X.XX/X..X/X..X",
        "O": ".XX./X..X/X..X/X..X/.XX.", "P": "XXX./X..X/XXX./X.../X...",
        "Q": ".XX./X..X/X..X/X.X./.X.X", "R": "XXX./X..X/XXX./X.X./X..X",
        "S": ".XXX/X.../.XX./...X/XXX.", "T": "XXX/.X./.X./.X./.X.",
        "U": "X..X/X..X/X..X/X..X/.XX.", "V": "X...X/X...X/.X.X./.X.X./..X..",
        "W": "X...X/X...X/X.X.X/XX.XX/X...X", "X": "X..X/X..X/.XX./X..X/X..X",
        "Y": "X.X/X.X/.X./.X./.X.", "Z": "XXXX/...X/.XX./X.../XXXX",
        "0": ".X./X.X/X.X/X.X/.X.", "1": ".X./XX./.X./.X./XXX",
        "2": "XX./..X/.X./X../XXX", "3": "XX./..X/.X./..X/XX.",
        "4": "X.X/X.X/XXX/..X/..X", "5": "XXX/X../XX./..X/XX.",
        "6": ".XX/X../XX./X.X/.X.", "7": "XXX/..X/.X./.X./.X.",
        "8": ".X./X.X/.X./X.X/.X.", "9": ".X./X.X/.XX/..X/XX.",
        "\"": "X.X/X.X/.../.../...", "@": ".XX./X.XX/X.XX/X.../.XXX",
        "…": "...../...../...../...../X.X.X", ".": "././././X", ":": "./X/./X/.",
        "(": ".X/X./X./X./.X", ")": "X./.X/.X/.X/X.", "-": ".../.../XXX/.../...",
        "'": "X/X/././.", "!": "X/X/X/./X", "_": "..../..../..../..../XXXX",
        "+": ".../.X./XXX/.X./...", "\\": "X../X../.X./..X/..X", "/": "..X/..X/.X./X../X..",
        "[": "XX/X./X./X./XX", "]": "XX/.X/.X/.X/XX", "^": ".X./X.X/.../.../...",
        "&": ".X../X.X./.X.X/X.X./.X.X", "%": "X.X/..X/.X./X../X.X", ",": "./././X/X",
        "=": ".../XXX/.../XXX/...", "$": ".XX/XX./.X./.XX/XX.",
        "#": ".X.X./XXXXX/.X.X./XXXXX/.X.X.", "?": "XX./..X/.X./.../.X.",
        "*": "X.X/.X./X.X/.../...", "<": "..X/.X./X../.X./..X", ">": "X../.X./..X/.X./X..",
        "Å": ".XX./.XX./X..X/XXXX/X..X", "Ö": "X..X/.XX./X..X/X..X/.XX.",
        "Ä": "X..X/.XX./X..X/XXXX/X..X", " ": "..././././...",
    ]

    private static var cache: [Character: [String]] = [:]

    /// Rows of the glyph for `ch` (unknown characters render as "?").
    static func glyph(_ ch: Character) -> [String] {
        let key = Character(String(ch).uppercased())
        if let g = cache[key] { return g }
        let rows = (glyphs[key] ?? glyphs["?"]!).split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        cache[key] = rows
        return rows
    }

    static func width(of rows: [String]) -> Int { rows.map(\.count).max() ?? 0 }

    // MARK: TEXT.BMP layout

    /// Characters in the order of TEXT.BMP's three rows (nil = unused cell).
    static let textRows: [[Character?]] = [
        Array("abcdefghijklmnopqrstuvwxyz\"@").map { Optional($0) } + [nil, nil, " "],
        Array("0123456789….:()-'!_+\\/[]^&%,=$#").map { Optional($0) },
        Array("ÅÖÄ?*").map { Optional($0) },
    ]

    private static let cellIndex: [Character: (col: Int, row: Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (r, row) in textRows.enumerated() {
            for (c, ch) in row.enumerated() { if let ch { m[ch] = (c, r) } }
        }
        m["å"] = (0, 2); m["ö"] = (1, 2); m["ä"] = (2, 2)
        m["<"] = (22, 1); m["{"] = (22, 1); m[">"] = (23, 1); m["}"] = (23, 1)
        return m
    }()

    private static let substitutions: [Character: String] = [
        "ı": "i", "ß": "ss", "æ": "ae", "ø": "o", "œ": "oe", "ł": "l", "đ": "d", "þ": "th",
        "ð": "d", "“": "\"", "”": "\"", "„": "\"", "‘": "'", "’": "'", "‚": ",", "–": "-",
        "—": "-", "×": "x", "·": ".", "|": "!", "~": "-", "`": "'", ";": ":",
    ]

    /// Maps a string onto TEXT.BMP cells, folding accents the font does not have.
    static func cells(for s: String) -> [(col: Int, row: Int)] {
        var out: [(col: Int, row: Int)] = []
        for ch in s.lowercased() {
            if let c = cellIndex[ch] { out.append(c); continue }
            let folded = substitutions[ch]
                ?? String(ch).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            for f in folded {
                out.append(cellIndex[f] ?? cellIndex[Character(f.lowercased())] ?? cellIndex["?"]!)
            }
        }
        return out
    }
}
