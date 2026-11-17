# ZNP Z01 BLE protocol

Everything the Z01 does over Bluetooth Low Energy, byte by byte. It was worked out from iOS PacketLogger captures of the stock app and then confirmed by driving real badges from our own code (the VRTX, Milo and KOVA apps).

Every value is hex. **BE** means big-endian and **LE** means little-endian.

- [1. The chip and the radio](#1-the-chip-and-the-radio)
- [2. Services and characteristics](#2-services-and-characteristics)
- [3. Connecting](#3-connecting)
- [4. Authentication](#4-authentication-the-reflection-trick)
- [5. RCSP frames](#5-rcsp-frames)
- [6. After auth: clock and battery](#6-after-auth-clock-and-battery)
- [7. The side button](#7-the-side-button)
- [8. Screens](#8-screens)
- [9. Text on the screen](#9-text-on-the-screen)
- [10. The microphone](#10-the-microphone)
- [11. The speaker](#11-the-speaker)
- [12. Files on the badge](#12-files-on-the-badge)
- [13. Uploading a file](#13-uploading-a-file)
- [14. Opcode table](#14-opcode-table)
- [15. Timings that matter](#15-timings-that-matter)
- [16. What is still unknown](#16-what-is-still-unknown)

---

## 1. The chip and the radio

The Z01 runs on a **JieLi** Bluetooth SoC, a chip family you also find in cheap earbuds and smartwatches. It's dual-mode:

- **BLE** carries control, screen text, files and the **microphone** (as Opus data, not as a Bluetooth audio profile).
- **Classic Bluetooth** makes the badge a normal **audio output** named `Z01`. That's how its speaker plays sound (see [§11](#11-the-speaker)).

It speaks JieLi's own **RCSP** protocol on one service, plus a small vendor service for screen text.

## 2. Services and characteristics

Short UUIDs expand to `0000xxxx-0000-1000-8000-00805f9b34fb`.

| Service | Characteristic | Direction | Use |
|---|---|---|---|
| `AE00` | `AE01` | phone → badge (write without response) | auth + RCSP commands |
| `AE00` | `AE02` | badge → phone (notify) | auth + RCSP responses, button, mic audio |
| `DF97` | `DF98` | phone → badge (write) | screen text frames |
| `DF97` | `DF99` | badge → phone (notify) | screen text acks |
| `FEE7` | | | advertised; not used by us |

**Advertised name:** starts with `Z01`. Scan for any device and filter on the name: the services aren't always in the advertisement.

## 3. Connecting

1. Scan, keep the first device whose name starts with `Z01`, connect.
2. Discover services `AE00` and `DF97`, then all their characteristics.
3. Turn on notifications for every characteristic that supports them (`AE02`, `DF99`).
4. When `AE02` reports notifications are on, wait **~0.5 s**, then start authentication.
5. On Android, request a larger MTU (e.g. 247) before you write anything. iOS negotiates it for you.

Only one phone app can hold the badge at a time. If the stock app is running, close it or turn its Bluetooth access off.

**Writes longer than the MTU:** cut the frame into pieces of `maxWriteLength` bytes and send them in order. The badge joins them back together. Don't let another frame interleave with a frame that's half sent.

## 4. Authentication (the reflection trick)

Before it accepts any command, the badge runs JieLi's mutual challenge-response on `AE01`/`AE02`. These messages are raw bytes, not RCSP frames.

| Message | Bytes |
|---|---|
| challenge | `00` + 16 random bytes |
| answer | `01` + 16 bytes = E(challenge) |
| accepted | `02 70 61 73 73` (`02` + `"pass"`) |

E is a secret JieLi function and we don't know it. **We don't need it:** the badge computes E for any challenge it receives. So when the badge challenges us, we send its own challenge back to it, and it gives us the answer it expects to hear.

```
phone                                   badge
  │ 00 <16 random>                        │   we challenge the badge
  │ ◀──────────────── 01 <16 bytes>       │   its answer (we accept it unchecked)
  │ 02 "pass"                             │
  │ ◀──────────────── 00 <16 bytes = C>   │   the badge challenges us
  │ 00 C                                  │   reflect C back to the badge…
  │ ◀──────────────── 01 E(C)             │   …and it encrypts it for us
  │ 01 E(C)                               │   we give that as our answer
  │ ◀──────────────── 02 "pass"           │   done: the link is ready
```

State machine (feed it every `AE02` notification that isn't an RCSP frame):

| We're in | We get | We send | Next |
|---|---|---|---|
| challenged | `01 …` | `02 "pass"` | passed |
| any | `00 C` | `00 C` | reflecting |
| reflecting | `01 X` | `01 X` | responded |
| passed or responded | `02 "pass"` | | **ready** |

If nothing happens for 10 s, disconnect and try again. That usually means another app grabbed the badge.

## 5. RCSP frames

After auth, everything on `AE01`/`AE02` is an RCSP frame:

```
FE DC BA | flag | opcode | len (2, BE) | params[len] | EF
```

- **flag** bit 7: `1` = command, `0` = response. Bit 6: `1` = a response is wanted.
  - `C0`: a command that wants an answer (the usual one)
  - `80`: a command with no answer wanted (screen switches, bulk data)
  - `00`: a response
- **Command params** start with a sequence number `sn` (one byte, wraps around). We call the bytes after it **data**.
- **Response params** start with `status, sn`. `status 00` means OK. The bytes after `sn` are the response's **data**.
- A response carries the `sn` of the command it answers.

Example, the command that switches to the thinking screen with `sn = 07`:

```
FE DC BA  80  FF  00 05  07 FF F7 F1 04  EF
          │   │   │      │  └─ data
          │   │   │      └─ sn
          │   │   └─ len = 5
          │   └─ opcode FF
          └─ command, no answer wanted
```

The badge also sends **commands to us** (button, voice, upload requests). Answer the ones that want an answer with `flag 00`, `status 00` and their `sn`.

## 6. After auth: clock and battery

The stock app does both right after auth, and so should you.

**Set the clock** with op `08`:

```
data: 02 08 00 | year (2, BE) | month | day | hour | minute | second
```

**Battery and device info** with op `03` (GetTargetInfo):

```
data: FF FF FF FF
```

The response data is a list of TLVs, `len | type | value[len-1]`. The first byte of type `01` is the **battery level in %**. The other types aren't identified yet. Keep them raw and log them.

## 7. The side button

A press on the side button arrives as a command, op `FF`, flag `80`:

| data | meaning |
|---|---|
| `FF F7 F1 00` | the button was pressed: the badge opens a voice session |
| `FF F7 F1 01` | the wearer ended the session on the badge |

> **Watch out for the QR code.** A press puts the firmware into a voice session that waits for the app to open the mic. If the app doesn't, the badge shows the stock app's "App not connected" QR code, even when you're connected and authenticated. Open the mic (op `04`, [§10](#10-the-microphone)) right after the press and keep it open for **at least 2 s**, then close it (op `05`) and switch to the thinking screen. The QR then stays away. Closing the mic straight away doesn't prevent it.

## 8. Screens

The badge has a round **360 × 360** screen. The firmware draws its own session screens. Switch between them with op `FF`, flag `80`:

```
data: FF F7 F1 <state>
```

| state | screen |
|---|---|
| `02` | **replying**: shows the text you stream on `DF98` |
| `03` | **listening**: plays `s.avi` from the animation pack |
| `04` | **thinking**: the firmware's own animation (can't be replaced) |

To leave the session and go back to the badge's own screens (clock, faces), send op `05` with data `00`. It's the same command that closes the mic.

To show a picture already stored on the badge:

```
op 1A, data: 03 04 "/VIE_xxx"
```

## 9. Text on the screen

Text goes to `DF98` (the vendor service), not to RCSP. Switch to the **replying** screen (`FF F7 F1 02`) first.

```
88 88 11 01 | n+5 | 00 n 00 00 n | UTF-8 text[n]
```

- Send **2 characters per frame**. A character with an accent counts as one character, so never split its bytes.
- The badge acks each frame on `DF99` with `88 88 11 02 01 00`.
- Pace the frames: wait for the ack, then leave ~120 ms between frames. If no ack arrives within ~350 ms, send the next frame anyway.
- The badge renders the text in its own font, one flowing line that scrolls. It **can't draw emoji**. Strip them along with markdown (`* _ # \``), and turn curly quotes, dashes and `…` into plain ASCII.

Example, the two characters `Hi`:

```
88 88 11 01 07 00 02 00 00 02 48 69
```

## 10. The microphone

The badge mic is plain GATT data. It never opens a Bluetooth call profile (HFP), so music on the phone keeps playing.

**Open:** op `04`, flag `C0`, data `02 10 00`. The badge answers `status 00`, or something else if it refuses.

**Voice:** the badge then sends commands op `01`, flag `80` (no answer wanted):

```
data: count | count × Opus packets of equal size
```

Each packet is **Opus, 16 kHz, mono, 20 ms (320 samples)**. In practice a frame holds 4 packets, which is 80 ms of audio. Split the body evenly: `size = (data.length − 1) / count`.

**Close:** op `05`, data `00`. This also leaves the session screen.

Decoding:

- **iOS:** `AVAudioConverter` from `kAudioFormatOpus` (16 kHz, 1 channel, 320 frames per packet) to Float32 PCM. See [`Z01Mic.swift`](../examples/ios/Z01Kit/Sources/Z01Kit/Z01Mic.swift).
- **Android:** `MediaCodec` `audio/opus` with an `OpusHead` as `csd-0`. See [`OpusDecoder.kt`](../examples/android/app/src/main/java/dev/znpre/quickstart/OpusDecoder.kt).
- **Desktop:** libopus, at 16 kHz mono.

Health check for a live stream: if no voice packet arrives for ~150 ms, you're losing frames. Falling back to the phone mic is a good idea.

## 11. The speaker

The speaker isn't on BLE. The Z01 is also a classic Bluetooth audio device and shows up in the phone's audio outputs as **`Z01`**. Pick it as the output (iOS Control Center, or Android's output switcher) and any sound your app plays, text-to-speech included, comes out of the badge.

Nothing in the protocol is needed for this. It's why a voice assistant on the Z01 can use any TTS engine you like.

## 12. Files on the badge

The badge stores pictures and animations on a FAT16 flash volume with no folders. The paths we know:

| path | content |
|---|---|
| `/VIE_xxx` | a still picture (RU50 format), `xxx` = 3 chars A–Z / 0–9 |
| `/AVI` | the animation pack: `1.avi`…`6.avi` + `s.avi` (listening) |
| `WP_CFG.BIN` | wallpaper config (not decoded) |

| op | data | does |
|---|---|---|
| `1A` | `03 04 path` | show a stored picture |
| `1A` | `05 01 path` | delete a file |
| `1A` | `0B 00 path` | check a file (see below) |
| `1A` | `01 01 offset(4, BE) size(2, BE)` | read raw flash, **192 bytes max** per read |

**File check answer** (`status 00`):

| data | meaning |
|---|---|
| `00 size(4, BE) crc16(2, BE)` | the file exists |
| `FF 00 path EF` | missing (two empty answers with the same `sn` follow) |

**Raw flash read:** the answer's data has 2 extra bytes in front. Take the last `size` bytes. Offset 0 is a FAT16 boot sector. On the badges we probed, the root directory sits at `0x8000`, is `0x1000` bytes long, and lists every file.

The file formats themselves (RU50 pictures, the AVI pack, the MJPEG videos) are in [FILE-FORMATS.md](FILE-FORMATS.md).

## 13. Uploading a file

Uploads use JieLi's RCSP big-file transfer. After the start command, **the badge drives the transfer**: it asks for windows of the file and we send them.

```
 (1A 05 01 "/AVI")                         only when replacing a file: delete it first, ignore errors
  1A 02 01 size(4) "/VIE_xxx"              open the target file
  21 00                                    prepare
  27 00 00 00 00 03 01                     prepare
  1B size(4) crc16(2) "xxxxxxxx.tmp" 00    start; the answer's data = packet size (2, BE), usually 512
  ◀ 1D  00 len(2) offset(4)                the badge asks for a window of the file…
  ▶ 01  1D idx crc16(2) <chunk>            …send it in packets, flag 80, idx 0,1,2…
     (repeat: the badge often pulls the body first and the header last)
  ◀ 20                                     the badge asks for the file name
  ▶ answer 20: "VIE_xxx" 00 00
  ◀ 1C  00                                 the badge reports the end (00 = OK); answer it
  1A 02 00                                 close the file
  0C 00 C8 00 01 00 00 00 03 00 04 00 00 00 00
  ◀ 0D                                     the badge sends a 0D command; answer it
  1A 0B 00 "/VIE_xxx"                      read back size + CRC: did it arrive whole?
  1A 03 04 "/VIE_xxx"                      show it (skip this when replacing)
```

- Every CRC is **CRC-16/XMODEM** (poly `1021`, init `0000`), over the whole file in `1B` and over each chunk in the `01 1D` packets.
- Each step waits for its answer before the next one goes out. A non-zero status means the badge refused.
- Run a watchdog: 10 s without progress means the upload failed. Send op `1E` to cancel.
- A big file can keep the badge quiet for a while at the end. If every byte went out but the ending times out, check the file with `1A 0B 00` before you report a failure.

## 14. Opcode table

| op | who sends | flag | data | meaning |
|---|---|---|---|---|
| `01` | badge | `80` | `count + Opus packets` | mic audio |
| `01` | phone | `80` | `1D idx crc16 chunk` | upload data |
| `03` | phone | `C0` | `FF FF FF FF` | GetTargetInfo (battery) |
| `04` | phone | `C0` | `02 10 00` | open mic |
| `05` | phone | `C0` | `00` | close mic / leave session |
| `08` | phone | `C0` | `02 08 00 YYYY MM DD hh mm ss` | set clock |
| `0C` | phone | `C0` | see §13 | end of upload |
| `0D` | badge | `C0` | | end of upload, answer it |
| `1A` | phone | `C0` | `sub …` | file system (see §12, §13) |
| `1B` | phone | `C0` | `size crc name.tmp 00` | start upload |
| `1C` | badge | `C0` | `status` | upload finished |
| `1D` | badge | `C0` | `00 len offset` | send me this window |
| `1E` | phone | `C0` | | cancel upload |
| `20` | badge | `C0` | | what's the file name? |
| `21` | phone | `C0` | `00` | prepare upload |
| `27` | phone | `C0` | `00 00 00 00 03 01` | prepare upload |
| `FF` | phone | `80` | `FF F7 F1 02/03/04` | switch screen |
| `FF` | badge | `80` | `FF F7 F1 00/01` | button pressed / session ended |

## 15. Timings that matter

| what | value |
|---|---|
| wait after `AE02` notifications turn on, before auth | 0.5 s |
| auth timeout | 10 s |
| gap between text frames | ~120 ms (stock app: 110–180 ms) |
| text ack timeout | ~350 ms |
| shortest mic-open time that keeps the QR away after a press | 2 s |
| upload watchdog | 10 s without progress |
| flash read size | 192 bytes |
| a voice frame | 4 × 20 ms = 80 ms of audio |

## 16. What is still unknown

Help welcome. Open an issue or a PR:

- E, JieLi's auth function. We don't need it (see §4), but it would be nice to know.
- GetTargetInfo TLV types other than `01`, and a stable hardware ID (iOS hides the MAC).
- What `0C 00 C8 00 01 …` at the end of an upload configures.
- Whether the thinking screen (`04`) can be replaced without changing the firmware.
- The `FEE7` service.
- Whether `05 00` reliably closes a session that started without an open mic.
