import Foundation

/// Text for the badge screen, on the vendor channel (DF98 write, DF99 ack):
///
///     88 88 11 01 | n+5 | 00 n 00 00 n | UTF-8 text[n]
///
/// Two characters per frame. The badge acks each frame with `88 88 11 02 01 00`.
public enum ScreenText {
    public static let ack = Data([0x88, 0x88, 0x11, 0x02, 0x01, 0x00])
    public static let charactersPerFrame = 2

    public static func frame(_ text: Substring) -> Data {
        let bytes = Array(text.utf8.prefix(250))
        let n = UInt8(bytes.count)
        return Data([0x88, 0x88, 0x11, 0x01, n + 5, 0x00, n, 0x00, 0x00, n] + bytes)
    }

    /// Clean text cut into frames, in order. Characters are never split.
    public static func frames(for text: String) -> [Data] {
        var frames: [Data] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            frames.append(frame(rest.prefix(charactersPerFrame)))
            rest = rest.dropFirst(charactersPerFrame)
        }
        return frames
    }

    /// Makes streamed text screen-safe, piece by piece: one flowing line, single
    /// spaces (kept across pieces), no markdown, plain punctuation, no emoji
    /// (the badge font can't draw them).
    public struct Cleaner {
        private var pendingSpace = false
        private var started = false

        public init() {}

        public mutating func feed(_ piece: String) -> String {
            var out = ""
            for ch in piece {
                if ch.isWhitespace {
                    pendingSpace = started
                    continue
                }
                guard let safe = Self.safe(ch) else { continue }
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                started = true
                out += safe
            }
            return out
        }

        private static func safe(_ ch: Character) -> String? {
            switch ch {
            case "*", "_", "`", "#": return nil
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}": return "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}": return "\""
            case "\u{2013}", "\u{2014}", "\u{2212}", "\u{2022}", "\u{00B7}": return "-"
            case "\u{2026}": return "..."
            default:
                let emoji = ch.unicodeScalars.contains {
                    $0.properties.isEmojiPresentation || $0.value == 0x200D || $0.value == 0xFE0F
                        || (0x2190...0x2BFF).contains($0.value)
                }
                return emoji ? nil : String(ch)
            }
        }
    }
}
