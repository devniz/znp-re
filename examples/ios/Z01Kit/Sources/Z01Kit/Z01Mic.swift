import AVFoundation

/// The badge microphone. After `op 04 [02 10 00]` the badge sends `op 01` commands
/// whose data is `count` followed by `count` equal-size Opus packets, 16 kHz mono,
/// 20 ms each. `op 05 [00]` stops it. This turns them into 16 kHz Float32 PCM.
public final class Z01Mic {
    static let startData = Data([0x02, 0x10, 0x00])
    static let stopData = Data([0x00])
    public static let sampleRate = 16_000.0
    public static let samplesPerPacket: AVAudioFrameCount = 320

    public let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false)!
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.samplesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: input, to: outputFormat) else { return nil }
        inputFormat = input
        self.converter = converter
    }

    /// Clears decoder state between two utterances.
    public func reset() {
        converter.reset()
    }

    /// True for the badge's voice frames.
    static func isVoice(_ frame: RCSPFrame) -> Bool {
        frame.isCommand && frame.opcode == 0x01 && (frame.data.first ?? 0) > 0
    }

    /// The Opus packets in one voice frame's data.
    public static func packets(in data: Data) -> [Data] {
        guard let n = data.first.map(Int.init), n > 0 else { return [] }
        let body = Data(data.dropFirst())
        let size = body.count / n
        guard size > 0 else { return [] }
        return (0..<n).map { Data(body[($0 * size)..<(($0 + 1) * size)]) }
    }

    /// Opus packets to 16 kHz mono Float32 PCM.
    public func decode(_ packets: [Data]) -> AVAudioPCMBuffer? {
        guard !packets.isEmpty else { return nil }
        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packets.count),
                                            maximumPacketSize: packets.map(\.count).max() ?? 0)
        var offset = 0
        for (i, p) in packets.enumerated() {
            p.withUnsafeBytes { input.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: p.count) }
            input.packetDescriptions?[i] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.count))
            offset += p.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: Self.samplesPerPacket * AVAudioFrameCount(packets.count)) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}
