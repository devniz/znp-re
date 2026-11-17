<p align="center">
  <img src="docs/z01.webp" alt="The ZNP Z01 badge showing a purple face on its round screen" width="320" />
</p>

# ZNP-RE

**The ZNP Z01 AI badge, reverse engineered.** The complete Bluetooth protocol, plus working iOS and Android code, so you can build your own AI badge assistant with your own app, your own features and the AI model you choose.

We use it with [Claude](https://www.anthropic.com/claude). You can plug in anything.

```
press the badge ─▶ speak ─▶ your phone app ─▶ Claude ─▶ the answer on the badge screen
                                                      └▶ and out of the badge speaker
```

---

## The Z01 is just a mic and a speaker

Take the "AI" label off the Z01 and what's left is simple hardware: a **microphone**, a **speaker**, a small round screen, one button and a Bluetooth chip. It's the same set of parts as a basic cheap smartwatch, and the chip comes from the same family.

There's no AI inside. The badge only records your voice, sends it to a phone app over Bluetooth, and shows or plays whatever comes back. The intelligence was always in the app and the cloud service behind it.

So whoever controls the app controls the badge. This repo gives you that control.

## What you get

- **[The full BLE protocol](docs/PROTOCOL.md):** connecting, unlocking, the button, the microphone, the screens, text, files and uploads, byte by byte.
- **[How we did it](docs/HOW-WE-DID-IT.md):** the reverse engineering in plain words, and how we swapped the stock AI for Claude.
- **[An iOS quick start](examples/ios):** a Swift package (`Z01Kit`) and a small SwiftUI app. Press the button, talk, and Claude answers on the badge.
- **[An Android quick start](examples/android):** the same in Kotlin.
- **[A desktop probe](tools/z01_probe.py):** drive the badge from your laptop with Python in two minutes.
- **[File formats](docs/FILE-FORMATS.md):** push your own pictures and animated faces to the screen.

## Why build your own

The Z01 is a small, wearable mic and speaker. Pair it with your own app and it becomes whatever you want: a pocket assistant, a translator, a note taker, a kid-friendly talking toy. It's a great alternative to the upcoming Meta Charm keychain or any other intelligent AI badge toy, and you own the whole stack.

| | Stock app | Your app |
|---|---|---|
| **AI model** | whatever the vendor picked | any: Claude Opus, Sonnet or Haiku, or another provider, or a local model |
| **Features** | chat | anything you can write as a tool: email, calendar, music, smart home, directions, your own APIs |
| **Privacy** | your voice goes through the vendor's servers | badge → your phone → the AI provider you chose. No extra account, no middleman |
| **Cost** | tied to the vendor's service | the badge, plus what you use of your AI provider |
| **Personality** | fixed | your prompt, your voice, your faces on the screen |
| **Code** | closed | open, MIT |

A few more things that make it pleasant to build on:

- **Nothing to flash.** The firmware stays stock. You can't brick the badge, and the stock app still works if you go back.
- **The mic doesn't hijack your audio.** Voice comes over BLE as data, not as a phone call profile, so music keeps playing while you talk.
- **The speaker is just Bluetooth audio.** Pick "Z01" as the output and any text-to-speech engine plays through it.
- **The screen shows text as it streams.** Answers appear word by word while the model is still writing.

## Try it in two minutes (from your laptop)

Turn the badge on and close the stock app on your phone (only one app can hold the badge). Then:

```bash
pip install bleak
```

```bash
python3 tools/z01_probe.py --text "Hello from my laptop"
```

The badge connects, unlocks and shows your text. Add `--listen`, press the badge button and talk: the probe saves what the badge heard.

## Build your own app

### iOS

Follow [examples/ios](examples/ios). In short: create an iOS app in Xcode, add the local `Z01Kit` package, drop in the five QuickStart files, paste your Anthropic API key, run.

The heart of it fits on one screen:

```swift
import Z01Kit

let badge = Z01()
let listener = Listener()               // speech to text, QuickStart/Listener.swift
let claude = Claude(apiKey: myKey)      // streaming client, QuickStart/Claude.swift

badge.onEvent = { event in
    switch event {
    case .buttonPressed:                // 1. the wearer presses the button
        listener.start { _ in }
        badge.startMic()
    case .micAudio(let pcm):            // 2. the badge streams what it hears
        listener.append(pcm)
    default:
        break
    }
}
badge.start()

// 3. when they stop talking (the QuickStart app waits for 1.2 s of silence)
func answer() async throws {
    badge.stopMic()
    badge.setScreen(.thinking)
    let question = listener.stop()
    badge.beginReply()
    for try await piece in claude.stream(system: "Answer in one short spoken sentence.",
                                         messages: [.init(role: "user", text: question)]) {
        badge.appendReply(piece)        // 4. the answer appears on the badge as it's written
    }
}
```

### Android

Follow [examples/android](examples/android). Same structure in Kotlin: `Z01Link` for the badge, Android's `MediaCodec` for the audio, the official Anthropic Java SDK for Claude.

### Anything else

The protocol is plain BLE. Flutter, React Native, a Raspberry Pi or an ESP32 can all drive the badge. [PROTOCOL.md](docs/PROTOCOL.md) has everything, and the Python probe is a compact reference.

## The protocol at a glance

| | Channel | Bytes |
|---|---|---|
| unlock | `AE01` / `AE02` | JieLi challenge-response, solved by reflecting the badge's own challenge |
| button pressed | ← `AE02` | RCSP op `FF`, `FF F7 F1 00` |
| open mic | → `AE01` | RCSP op `04`, `02 10 00` |
| voice | ← `AE02` | RCSP op `01`, Opus packets, 16 kHz mono, 20 ms |
| close mic | → `AE01` | RCSP op `05`, `00` |
| screen | → `AE01` | RCSP op `FF`, `FF F7 F1 02` replying, `03` listening, `04` thinking |
| text | → `DF98` | `88 88 11 01 …`, 2 characters per frame, acked on `DF99` |
| battery | → `AE01` | RCSP op `03`, `FF FF FF FF` |
| speaker | classic Bluetooth | a normal audio output named `Z01` |

The full details, timings and gotchas are in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Ideas

- A translator: speak in one language, read the answer in another on the screen.
- A memory badge: "remember that I parked on level 3", then ask later.
- A kids' companion with a gentle persona and your own animated face.
- A meeting note taker that sends you a summary afterwards.
- A home controller: "turn off the living room lights".
- A fully offline assistant on a local model.

## Repository layout

```
docs/
  PROTOCOL.md         the BLE protocol, byte by byte
  HOW-WE-DID-IT.md    the reverse engineering, in plain words
  FILE-FORMATS.md     pictures, animation packs, videos
examples/
  ios/                Z01Kit (Swift package) + a SwiftUI quick-start app
  android/            the same in Kotlin
tools/
  z01_probe.py        drive the badge from a computer (Python + bleak)
```

## Status

| | |
|---|---|
| connect, unlock, reconnect | works on real badges |
| button, mic, screens, text | works on real badges |
| pictures, animation packs | works on real badges. Documented here, no sample code yet |
| iOS `Z01Kit` | unit-tested. A trimmed-down copy of the code our iOS apps run on real badges |
| iOS QuickStart app | compiles against the iOS SDK |
| Android quick start | a port, not yet compiled or tried on a badge |

What's still unknown is listed at the end of [PROTOCOL.md](docs/PROTOCOL.md#16-what-is-still-unknown).

## Contributing

Issues and pull requests are welcome, especially:

- captures from other firmware versions or other JieLi badges,
- the unknowns listed in the protocol doc,
- testing and fixes for the Android sample,
- ports to other platforms.

## Disclaimer

This is an independent project for interoperability, made by owners of the device. It isn't affiliated with or endorsed by ZNP, JieLi, Anthropic or Meta. No firmware was modified, and no keys or encryption were extracted or broken. Product names belong to their owners. Use it at your own risk.

## License

[MIT](LICENSE)
