# iOS quick start

A working voice assistant on the Z01 in about ten minutes: press the badge button, talk, and Claude answers on the badge screen and through its speaker.

```
Z01Kit/        the badge protocol as a Swift package (no dependencies)
QuickStart/    a small SwiftUI app that uses it with Claude
```

## Build it

You need Xcode 15+, an iPhone on iOS 16 or later, a Z01 and an [Anthropic API key](https://console.anthropic.com/).

1. **Free the badge.** Close the stock app or turn its Bluetooth access off. Only one app can hold the badge at a time.
2. In Xcode: **File › New › Project › iOS App**. Choose SwiftUI and call it whatever you like.
3. Delete the generated `ContentView.swift` and `<Name>App.swift`, then drag in the five files from [`QuickStart/`](QuickStart).
4. **File › Add Package Dependencies › Add Local…** and pick the [`Z01Kit`](Z01Kit) folder. Add the `Z01Kit` library to your app target.
5. In the target's **Info** tab, add:
   - `NSBluetoothAlwaysUsageDescription`: *Connects to your Z01 badge.*
   - `NSSpeechRecognitionUsageDescription`: *Turns what you say to the badge into text.*
6. Pick your team under **Signing & Capabilities**, plug in your iPhone and press **Run**.
7. In the app, paste your API key and tap **Save key**.
8. Tap the speaker button and pick **Z01**, so answers play on the badge.

Now press the button on the badge and ask something.

## How it works

| File | Job |
|---|---|
| [`Z01Kit/Z01.swift`](Z01Kit/Sources/Z01Kit/Z01.swift) | connects, unlocks, reads the button, opens the mic, switches screens, streams text |
| [`Z01Kit/Z01Mic.swift`](Z01Kit/Sources/Z01Kit/Z01Mic.swift) | decodes the badge's Opus audio to PCM |
| [`QuickStart/Listener.swift`](QuickStart/Listener.swift) | speech to text with Apple's recognizer (on-device when it can) |
| [`QuickStart/Claude.swift`](QuickStart/Claude.swift) | streams the answer from the Claude API |
| [`QuickStart/Assistant.swift`](QuickStart/Assistant.swift) | the loop: button → listen → think → show + speak |

The iPhone's own microphone is never used. The voice always comes from the badge.

## Make it yours

- **Personality:** edit `Assistant.persona`.
- **Model:** change `model` in `Claude.swift`. `claude-opus-5-5` is the default. `claude-haiku-5-5` is the fastest and cheapest.
- **Abilities:** add [tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview) to the request in `Claude.swift` (send a message, check the weather, control your lights), run them in `Assistant`, and send the results back.
- **Another AI:** `Assistant` only needs a stream of text. Swap `Claude` for any model you like, local ones included.
- **Voice:** `speak(_:)` uses the built-in iOS voice. Any TTS engine works, because the badge is a normal Bluetooth speaker.

## Using Z01Kit on its own

```swift
import Z01Kit

let badge = Z01()
badge.onEvent = { event in
    switch event {
    case .state(.ready):
        badge.showText("Hello from my own app!")
    case .buttonPressed:
        badge.startMic()                 // keep it open ≥ 2 s after a press
    case .micAudio(let pcm):
        _ = pcm                          // 16 kHz mono Float32
    default:
        break
    }
}
badge.start()
```

Run the protocol tests on a Mac with `swift test` in `Z01Kit/`.

`Z01Kit` is a trimmed-down copy of the BLE code our own iOS apps run on real badges. The QuickStart app around it compiles against the iOS SDK but is new, so tell us if something misbehaves on your badge.

## Before you ship it

This sample keeps your API key on the phone, which is fine for your own device. In an app other people install, call Claude from your own server instead, so the key never ships inside the app.
