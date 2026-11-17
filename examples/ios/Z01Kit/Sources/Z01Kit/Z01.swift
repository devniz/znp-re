import AVFoundation
import CoreBluetooth

/// The ZNP Z01 badge over BLE: connect, authenticate, read the button, open the
/// mic, switch screens and stream text. Use it from the main thread; `onEvent`
/// arrives there too.
///
///     let badge = Z01()
///     badge.onEvent = { event in … }
///     badge.start()
///
/// The badge's speaker isn't here: it's a normal Bluetooth audio output named
/// "Z01". Choose it as the phone's output and your app's sound plays on the badge.
public final class Z01: NSObject {
    public enum State: Equatable {
        case bluetoothOff, unauthorized, searching, connecting, authenticating, ready
    }

    /// The firmware's own session screens.
    public enum Screen: UInt8 {
        /// Shows the text you stream with `appendReply`.
        case replying = 0x02
        /// Plays the listening animation (`s.avi`).
        case listening = 0x03
        /// The firmware's thinking animation.
        case thinking = 0x04
    }

    public enum Event {
        case state(State)
        case battery(Int)
        /// The side button. The badge now waits for the mic: open it (see `startMic`).
        case buttonPressed
        /// The wearer ended the session on the badge.
        case sessionEnded
        case micOpened
        case micRefused
        /// 16 kHz mono Float32 audio from the badge mic.
        case micAudio(AVAudioPCMBuffer)
    }

    public var onEvent: ((Event) -> Void)?
    public private(set) var state = State.bluetoothOff {
        didSet { if state != oldValue { onEvent?(.state(state)) } }
    }
    public private(set) var battery: Int?
    public private(set) var isMicOpen = false
    public var name: String? { peripheral?.name }

    private static let services = [CBUUID(string: "AE00"), CBUUID(string: "DF97")]
    private static let rcspWrite = CBUUID(string: "AE01")
    private static let rcspNotify = CBUUID(string: "AE02")
    private static let textWrite = CBUUID(string: "DF98")
    private static let textNotify = CBUUID(string: "DF99")
    private static let buttonPressed = Data([0xFF, 0xF7, 0xF1, 0x00])
    private static let sessionEnded = Data([0xFF, 0xF7, 0xF1, 0x01])
    private static let textGap: TimeInterval = 0.12
    private static let textAckTimeout: TimeInterval = 0.35

    private let rememberKey: String
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var auth: JieLiAuth?
    private var sn: UInt8 = 0
    /// Write pieces waiting for room on the link, in order.
    private var writes: [(data: Data, to: CBCharacteristic, type: CBCharacteristicWriteType)] = []

    private let mic = Z01Mic()
    private var micSn: UInt8?

    private var cleaner = ScreenText.Cleaner()
    private var textFrames: [Data] = []
    private var sendingText = false
    private var textGeneration = 0
    private var lastTextAt = Date.distantPast

    /// `rememberKey` stores the last badge, so the app reconnects to it directly.
    public init(rememberKey: String = "z01.badge") {
        self.rememberKey = rememberKey
        super.init()
    }

    // MARK: - Public API

    /// Starts looking for a badge. From then on it reconnects by itself.
    public func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Forgets the remembered badge and searches again.
    public func forget() {
        UserDefaults.standard.removeObject(forKey: rememberKey)
        let old = peripheral
        linkLost()
        peripheral = nil
        if let old { central?.cancelPeripheralConnection(old) }
        find()
    }

    public func setScreen(_ screen: Screen) {
        clearText()
        send(opcode: 0xFF, data: Data([0xFF, 0xF7, 0xF1, screen.rawValue]), flag: RCSPFrame.commandNoReply)
    }

    /// Leaves the session screen (and closes the mic if it's open).
    public func endSession() {
        clearText()
        isMicOpen = false
        micSn = nil
        send(opcode: 0x05, data: Z01Mic.stopData)
    }

    /// Opens the badge mic. `.micOpened`, then `.micAudio`, arrive as events.
    /// After a button press, keep it open for at least 2 s, or the badge shows the
    /// stock app's "App not connected" QR code.
    public func startMic() {
        guard state == .ready, !isMicOpen else { return }
        mic?.reset()
        isMicOpen = true
        micSn = send(opcode: 0x04, data: Z01Mic.startData)
    }

    /// Closes the badge mic. This also leaves the session screen.
    public func stopMic() {
        guard isMicOpen else { return }
        endSession()
    }

    /// Shows a whole text on the replying screen.
    public func showText(_ text: String) {
        beginReply()
        appendReply(text)
    }

    /// Switches to the replying screen and clears it, ready for `appendReply`.
    public func beginReply() {
        setScreen(.replying)
        cleaner = ScreenText.Cleaner()
    }

    /// Adds a streamed piece of text (from Claude, say) to the screen.
    public func appendReply(_ piece: String) {
        guard state == .ready else { return }
        textFrames += ScreenText.frames(for: cleaner.feed(piece))
        if !sendingText {
            sendingText = true
            sendNextText()
        }
    }

    /// Asks the badge for its battery level again (`.battery` follows).
    public func refreshBattery() {
        send(opcode: 0x03, data: Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    // MARK: - Text pacing

    private func clearText() {
        textFrames = []
        sendingText = false
        textGeneration += 1
    }

    private func sendNextText() {
        guard sendingText, !textFrames.isEmpty else {
            sendingText = false
            return
        }
        write(textFrames.removeFirst(), to: Self.textWrite)
        lastTextAt = Date()
        scheduleNextText(after: Self.textAckTimeout) // no ack: carry on anyway
    }

    private func scheduleNextText(after delay: TimeInterval) {
        textGeneration += 1
        let generation = textGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.textGeneration == generation else { return }
            self.sendNextText()
        }
    }

    private func textAcked() {
        guard sendingText else { return }
        scheduleNextText(after: max(0, Self.textGap - Date().timeIntervalSince(lastTextAt)))
    }

    // MARK: - Writing

    /// Sends an RCSP command and returns its sequence number.
    @discardableResult
    private func send(opcode: UInt8, data: Data, flag: UInt8 = RCSPFrame.command) -> UInt8 {
        guard state == .ready else { return 0 }
        sn &+= 1
        write(RCSPFrame(flag: flag, opcode: opcode, params: Data([sn]) + data).encoded, to: Self.rcspWrite)
        return sn
    }

    /// Queues one frame, cut to the link's write size. The badge joins the pieces.
    private func write(_ data: Data, to uuid: CBUUID) {
        guard let p = peripheral, let c = characteristics[uuid] else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let size = max(20, p.maximumWriteValueLength(for: type))
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(data.endIndex, start + size)
            writes.append((Data(data[start..<end]), c, type))
            start = end
        }
        flush()
    }

    private func flush() {
        guard let p = peripheral else { writes = []; return }
        while let next = writes.first {
            if next.type == .withoutResponse, !p.canSendWriteWithoutResponse { return }
            writes.removeFirst()
            p.writeValue(next.data, for: next.to, type: next.type)
        }
    }

    // MARK: - Connection

    private func find() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        if let id = UserDefaults.standard.string(forKey: rememberKey).flatMap(UUID.init(uuidString:)),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else if let p = central.retrieveConnectedPeripherals(withServices: Self.services).first {
            connect(p)
        } else {
            state = .searching
            // The services aren't always advertised: scan for everything, match the name.
            central.scanForPeripherals(withServices: nil)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central?.connect(p) // no timeout: completes whenever the badge is in range
    }

    private func authenticated() {
        state = .ready
        syncClock()
        refreshBattery()
    }

    /// `op 08`: `02 08 00 YYYY MM DD hh mm ss`, as the stock app does after auth.
    private func syncClock() {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = c.year ?? 2026
        let rest = [c.month, c.day, c.hour, c.minute, c.second].map { UInt8($0 ?? 0) }
        send(opcode: 0x08, data: Data([0x02, 0x08, 0x00, UInt8(year >> 8), UInt8(year & 0xFF)] + rest))
    }

    private func linkLost() {
        characteristics = [:]
        auth = nil
        writes = []
        clearText()
        micSn = nil
        if isMicOpen {
            isMicOpen = false
            onEvent?(.micRefused)
        }
    }

    // MARK: - Incoming

    private func received(_ frame: RCSPFrame) {
        if Z01Mic.isVoice(frame) {
            guard isMicOpen, let buffer = mic?.decode(Z01Mic.packets(in: frame.data)) else { return }
            onEvent?(.micAudio(buffer))
        } else if !frame.isCommand, frame.opcode == 0x04, let micSn, frame.sn == micSn {
            self.micSn = nil
            if frame.status == 0 {
                onEvent?(.micOpened)
            } else {
                isMicOpen = false
                onEvent?(.micRefused)
            }
        } else if frame.isCommand, frame.opcode == 0xFF, frame.data == Self.buttonPressed {
            onEvent?(.buttonPressed)
        } else if frame.isCommand, frame.opcode == 0xFF, frame.data == Self.sessionEnded {
            isMicOpen = false
            onEvent?(.sessionEnded)
        } else if !frame.isCommand, frame.opcode == 0x03, frame.status == 0, let level = Self.battery(in: frame.data) {
            battery = level
            onEvent?(.battery(level))
        }
    }

    /// GetTargetInfo answers with TLVs `len type value[len-1]`; type 01 starts with the battery %.
    static func battery(in data: Data) -> Int? {
        let b = Array(data)
        var i = 0
        while i + 1 < b.count {
            let len = Int(b[i])
            guard len > 0, i + len < b.count else { return nil }
            if b[i + 1] == 0x01, len >= 2 { return Int(b[i + 2]) }
            i += len + 1
        }
        return nil
    }
}

// MARK: - CoreBluetooth

extension Z01: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let p = peripheral { connect(p) } else { find() }
        case .unauthorized:
            linkLost()
            state = .unauthorized
        default:
            linkLost()
            state = .bluetoothOff
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? ad[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.hasPrefix("Z01") else { return }
        central.stopScan()
        connect(p)
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: rememberKey)
        state = .authenticating
        p.discoverServices(Self.services)
        // A stuck handshake (another app holds the badge, say): drop and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.peripheral === p, self.state == .authenticating else { return }
            central.cancelPeripheralConnection(p)
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        central.connect(p)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        linkLost()
        state = .connecting
        central.connect(p)
    }
}

extension Z01: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            characteristics[c.uuid] = c
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.rcspNotify, c.isNotifying else { return }
        let auth = JieLiAuth { [weak self] in self?.write($0, to: Self.rcspWrite) }
        auth.onComplete = { [weak self] in self?.authenticated() }
        self.auth = auth
        // Let the other subscriptions settle before the handshake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { auth.start() }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        flush()
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        switch c.uuid {
        case Self.textNotify:
            if data == ScreenText.ack { textAcked() }
        case Self.rcspNotify:
            if let frame = RCSPFrame.parse(data) {
                received(frame)
            } else {
                auth?.handle(data)
            }
        default:
            break
        }
    }
}
