import AVFoundation
import Speech

/// Turns the badge mic's audio into text with Apple's speech recognizer.
/// It needs Speech Recognition permission, not microphone permission: the
/// iPhone's own mic is never used.
final class Listener {
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var text = ""

    static func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// `onText` gets the transcript so far, each time it changes (main thread).
    func start(onText: @escaping (String) -> Void) {
        stop()
        text = ""
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                self.text = text
                onText(text)
            }
        }
    }

    /// Feed it every buffer from the badge mic.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Ends the utterance and returns what was heard.
    @discardableResult
    func stop() -> String {
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        return text
    }
}
