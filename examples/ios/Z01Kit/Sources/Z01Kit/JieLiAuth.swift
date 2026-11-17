import Foundation

/// JieLi's mutual challenge-response, on AE01 (write) / AE02 (notify):
///
///     challenge  00 + 16 random bytes
///     answer     01 + E(challenge)       E is JieLi's secret function
///     accepted   02 "pass"
///
/// We don't know E, but the badge computes it for any challenge it gets. So when
/// the badge challenges us, we send that same challenge back to it, and return
/// its answer as ours. See docs/PROTOCOL.md §4.
final class JieLiAuth {
    private enum State { case idle, challenged, passed, reflecting, responded, done }

    static let pass = Data([0x02]) + Data("pass".utf8)

    var onComplete: (() -> Void)?
    private var state = State.idle
    private let send: (Data) -> Void

    /// `send` writes raw bytes to AE01.
    init(send: @escaping (Data) -> Void) {
        self.send = send
    }

    func start() {
        let challenge = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        state = .challenged
        send(Data([0x00]) + challenge)
    }

    /// Feed every AE02 notification that isn't an RCSP frame.
    func handle(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01 where state == .challenged:
            // The badge's answer to our challenge. We can't check it, so we accept it.
            state = .passed
            send(Self.pass)
        case 0x01 where state == .reflecting:
            // The badge scrambled its own challenge for us: that's our answer.
            state = .responded
            send(Data([0x01]) + data.dropFirst())
        case 0x00:
            // The badge challenges us: ask it to scramble that same challenge.
            state = .reflecting
            send(data)
        case 0x02 where data == Self.pass:
            if state == .responded || state == .passed {
                state = .done
                onComplete?()
            }
        default:
            break
        }
    }
}
