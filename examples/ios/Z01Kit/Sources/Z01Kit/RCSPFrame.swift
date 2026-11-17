import Foundation

/// A JieLi RCSP frame, as sent on AE01 and received on AE02 once the link is authenticated:
///
///     FE DC BA | flag | opcode | len (2, BE) | params[len] | EF
///
/// `flag` bit 7: command (1) or response (0). Bit 6: a response is wanted.
/// Command params start with `sn`; response params start with `status, sn`.
public struct RCSPFrame: Equatable {
    static let header: [UInt8] = [0xFE, 0xDC, 0xBA]
    static let end: UInt8 = 0xEF

    /// A command that wants an answer.
    public static let command: UInt8 = 0xC0
    /// A command with no answer wanted (screen switches, bulk data).
    public static let commandNoReply: UInt8 = 0x80
    public static let response: UInt8 = 0x00

    public let flag: UInt8
    public let opcode: UInt8
    public let params: Data

    public init(flag: UInt8, opcode: UInt8, params: Data) {
        self.flag = flag
        self.opcode = opcode
        self.params = params
    }

    public var isCommand: Bool { flag & 0x80 != 0 }
    /// The sequence number: params[0] for a command, params[1] for a response.
    public var sn: UInt8? {
        let p = Array(params)
        return isCommand ? p.first : (p.count > 1 ? p[1] : nil)
    }
    /// A response's status (00 = OK). Nil for commands.
    public var status: UInt8? { isCommand ? nil : params.first }
    /// The params after `sn` (commands) or after `status, sn` (responses).
    public var data: Data { Data(params.dropFirst(isCommand ? 1 : 2)) }

    public var encoded: Data {
        let n = params.count
        return Data(Self.header + [flag, opcode, UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + params + Data([Self.end])
    }

    /// Nil if `data` isn't one whole RCSP frame (auth messages aren't).
    public static func parse(_ data: Data) -> RCSPFrame? {
        let b = Array(data)
        guard b.count >= 8, Array(b[0..<3]) == header, b.last == end else { return nil }
        let len = Int(b[5]) << 8 | Int(b[6])
        guard b.count == 8 + len else { return nil }
        return RCSPFrame(flag: b[3], opcode: b[4], params: Data(b[7..<(7 + len)]))
    }
}
