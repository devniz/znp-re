import AVFoundation
import SwiftUI
import Z01Kit

/// The whole assistant loop:
///
///     button ─▶ badge mic ─▶ speech to text ─▶ Claude ─▶ badge screen + badge speaker
///
/// Change `persona` to give it a personality, or the model in `Claude.swift`.
@MainActor
final class Assistant: ObservableObject {
    @Published private(set) var status = "Starting…"
    @Published private(set) var battery: Int?
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var isListening = false
    @Published private(set) var isThinking = false

    static let persona = """
        You are a friendly voice assistant that lives in a small badge worn on the user's clothes. \
        Your words are shown on a tiny round screen and read aloud, so answer in one to three short \
        sentences of plain spoken text: no markdown, no lists, no emoji, no links.
        """

    let badge = Z01()
    private let listener = Listener()
    private let voice = AVSpeechSynthesizer()
    private var history: [Claude.Message] = []
    private var micOpenedAt = Date()
    private var silence: Task<Void, Never>?

    init() {
        badge.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        badge.start()
        Listener.requestPermission()
    }

    private func handle(_ event: Z01.Event) {
        switch event {
        case .state(let state):
            status = Self.describe(state)
        case .battery(let level):
            battery = level
        case .buttonPressed:
            listen()
        case .micAudio(let buffer):
            listener.append(buffer)
        case .micRefused:
            isListening = false
            silence?.cancel()
            listener.stop()
        case .sessionEnded:
            isListening = false
            silence?.cancel()
            listener.stop()
        case .micOpened:
            break
        }
    }

    /// Opens the badge mic and listens until the user stops talking.
    func listen() {
        guard badge.state == .ready, !isListening, !isThinking else { return }
        voice.stopSpeaking(at: .immediate)
        heard = ""
        reply = ""
        isListening = true
        micOpenedAt = Date()
        listener.start { [weak self] text in
            self?.heard = text
            self?.finish(afterSilence: 1.2) // 1.2 s without new words ends the question
        }
        badge.startMic()
        badge.setScreen(.listening)
        finish(afterSilence: 6) // nothing said at all
    }

    private func finish(afterSilence seconds: Double) {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopListening()
        }
    }

    private func stopListening() async {
        guard isListening else { return }
        isListening = false
        // After a button press the badge wants its mic open for 2 s or more,
        // or it shows the stock app's "App not connected" QR code.
        let open = Date().timeIntervalSince(micOpenedAt)
        if open < 2 { try? await Task.sleep(nanoseconds: UInt64((2 - open) * 1_000_000_000)) }
        badge.stopMic()
        let question = listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        heard = question
        await answer(question)
    }

    private func answer(_ question: String) async {
        isThinking = true
        defer { isThinking = false }
        badge.setScreen(.thinking)
        history.append(.init(role: "user", text: question))
        let claude = Claude(apiKey: Keychain.apiKey)
        var full = ""
        do {
            for try await piece in claude.stream(system: Self.persona, messages: history) {
                if full.isEmpty { badge.beginReply() }
                full += piece
                reply = full
                badge.appendReply(piece)
            }
            history.append(.init(role: "assistant", text: full))
            speak(full)
        } catch {
            history.removeLast()
            reply = error.localizedDescription
            badge.showText("Sorry, I couldn't answer that.")
        }
    }

    /// Plays on whatever the phone's audio output is. Pick "Z01" to hear it from the badge.
    private func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        voice.speak(utterance)
    }

    private static func describe(_ state: Z01.State) -> String {
        switch state {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth in Settings"
        case .searching: return "Looking for your Z01…"
        case .connecting: return "Connecting…"
        case .authenticating: return "Unlocking the badge…"
        case .ready: return "Ready: press the badge button"
        }
    }
}
