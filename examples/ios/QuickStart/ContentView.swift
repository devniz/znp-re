import AVKit
import SwiftUI

@main
struct QuickStartApp: App {
    @StateObject private var assistant = Assistant()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(assistant)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var assistant: Assistant
    @State private var apiKey = Keychain.apiKey ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Badge") {
                    LabeledContent("Status", value: assistant.status)
                    if let battery = assistant.battery {
                        LabeledContent("Battery", value: "\(battery) %")
                    }
                    HStack {
                        Text("Speaker output")
                        Spacer()
                        // Pick "Z01" here to hear the answers from the badge.
                        RoutePicker().frame(width: 32, height: 32)
                    }
                }

                Section("Claude") {
                    SecureField("Anthropic API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.apiKey = apiKey }
                    Button("Save key") { Keychain.apiKey = apiKey }
                }

                Section("Conversation") {
                    Button(assistant.isListening ? "Listening…" : "Talk") { assistant.listen() }
                        .disabled(assistant.isListening || assistant.isThinking)
                    if !assistant.heard.isEmpty {
                        Text(assistant.heard).foregroundStyle(.secondary)
                    }
                    if !assistant.reply.isEmpty {
                        Text(assistant.reply)
                    }
                }
            }
            .navigationTitle("Z01 + Claude")
        }
    }
}

/// The system's audio output picker (the AirPlay button).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
