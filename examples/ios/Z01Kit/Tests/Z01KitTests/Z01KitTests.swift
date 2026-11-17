import XCTest
@testable import Z01Kit

final class Z01KitTests: XCTestCase {
    func testFrameRoundTrip() {
        // The thinking screen, sn 07 (docs/PROTOCOL.md §5).
        let frame = RCSPFrame(flag: 0x80, opcode: 0xFF, params: Data([0x07, 0xFF, 0xF7, 0xF1, 0x04]))
        XCTAssertEqual(Array(frame.encoded),
                       [0xFE, 0xDC, 0xBA, 0x80, 0xFF, 0x00, 0x05, 0x07, 0xFF, 0xF7, 0xF1, 0x04, 0xEF])
        let parsed = RCSPFrame.parse(frame.encoded)
        XCTAssertEqual(parsed, frame)
        XCTAssertEqual(parsed?.sn, 0x07)
        XCTAssertEqual(parsed?.data, Data([0xFF, 0xF7, 0xF1, 0x04]))
    }

    func testResponseFields() {
        let frame = RCSPFrame(flag: 0x00, opcode: 0x04, params: Data([0x00, 0x2A]))
        XCTAssertFalse(frame.isCommand)
        XCTAssertEqual(frame.status, 0)
        XCTAssertEqual(frame.sn, 0x2A)
        XCTAssertTrue(frame.data.isEmpty)
    }

    func testAuthMessagesAreNotFrames() {
        XCTAssertNil(RCSPFrame.parse(Data([0x00]) + Data(repeating: 0xAB, count: 16)))
        XCTAssertNil(RCSPFrame.parse(JieLiAuth.pass))
    }

    func testAuthReflectsTheBadgeChallenge() {
        var sent: [Data] = []
        var done = false
        let auth = JieLiAuth { sent.append($0) }
        auth.onComplete = { done = true }

        auth.start()
        XCTAssertEqual(sent.last?.first, 0x00)
        XCTAssertEqual(sent.last?.count, 17)

        auth.handle(Data([0x01]) + Data(repeating: 0x11, count: 16)) // its answer to us
        XCTAssertEqual(sent.last, JieLiAuth.pass)

        let challenge = Data([0x00]) + Data(repeating: 0x22, count: 16)
        auth.handle(challenge)                                         // it challenges us
        XCTAssertEqual(sent.last, challenge)                           // we send it straight back

        let answer = Data(repeating: 0x33, count: 16)
        auth.handle(Data([0x01]) + answer)                             // it scrambles it for us
        XCTAssertEqual(sent.last, Data([0x01]) + answer)               // that's our answer

        XCTAssertFalse(done)
        auth.handle(JieLiAuth.pass)
        XCTAssertTrue(done)
    }

    func testTextFrames() {
        XCTAssertEqual(Array(ScreenText.frame("Hi")),
                       [0x88, 0x88, 0x11, 0x01, 0x07, 0x00, 0x02, 0x00, 0x00, 0x02, 0x48, 0x69])
        // "é" is two UTF-8 bytes but one character: never split.
        let frames = ScreenText.frames(for: "Café!")
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(Array(frames[1].suffix(3)), Array("fé".utf8))
    }

    func testCleanerKeepsSpacesAcrossPieces() {
        var cleaner = ScreenText.Cleaner()
        let out = cleaner.feed("**Hello**  ") + cleaner.feed("world 👋 — it’s\nme…")
        XCTAssertEqual(out, "Hello world - it's me...")
    }

    func testVoicePacketsSplitEvenly() {
        let data = Data([0x04]) + Data(0..<40)
        let packets = Z01Mic.packets(in: data)
        XCTAssertEqual(packets.count, 4)
        XCTAssertEqual(packets.map(\.count), [10, 10, 10, 10])
        XCTAssertEqual(packets[3].first, 30)
    }

    func testBatteryFromTargetInfo() {
        // len 03, type 01, battery 0x55 (85 %), then another field.
        XCTAssertEqual(Z01.battery(in: Data([0x03, 0x01, 0x55, 0x10, 0x02, 0x02, 0xAA])), 85)
        XCTAssertNil(Z01.battery(in: Data([0x02, 0x05, 0x01])))
    }

    func testOpusDecoderIsAvailable() {
        XCTAssertNotNil(Z01Mic())
    }
}
