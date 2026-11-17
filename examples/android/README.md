# Android quick start

The same assistant as the iOS sample, in Kotlin: press the badge button, talk, and Claude answers on the badge screen and through its speaker.

> **Status:** this is a port of the protocol code our iOS apps run on real badges. The Android version hasn't been compiled or tried on a badge yet, so expect small fixes. PRs are welcome.

| File | Job |
|---|---|
| [`Rcsp.kt`](app/src/main/java/dev/znpre/quickstart/Rcsp.kt) | RCSP frames, the auth trick, screen text |
| [`Z01Link.kt`](app/src/main/java/dev/znpre/quickstart/Z01Link.kt) | connects, unlocks, reads the button, opens the mic, switches screens, streams text |
| [`OpusDecoder.kt`](app/src/main/java/dev/znpre/quickstart/OpusDecoder.kt) | the badge's Opus audio to 16 kHz PCM, with Android's own decoder |
| [`Claude.kt`](app/src/main/java/dev/znpre/quickstart/Claude.kt) | streams the answer with the official Anthropic Java SDK |
| [`MainActivity.kt`](app/src/main/java/dev/znpre/quickstart/MainActivity.kt) | the loop: button → listen → think → show + speak |

## Set it up

You need Android Studio, a phone on **Android 13+** (the speech recognizer reads the badge's audio through an API added in 13), a Z01 and an [Anthropic API key](https://console.anthropic.com/).

1. **Free the badge.** Close the stock app or turn its Bluetooth access off.
2. **Pair the speaker.** In Android's Bluetooth settings, pair **Z01** as an audio device, so answers play on the badge.
3. In Android Studio: **New Project › No Activity**, package `dev.znpre.quickstart`, minimum SDK 33.
4. Copy the five files into `app/src/main/java/dev/znpre/quickstart/`.
5. In `app/build.gradle.kts`:

   ```kotlin
   dependencies {
       implementation("com.anthropic:anthropic-java:3.3.0")
   }
   ```

6. In `AndroidManifest.xml`:

   ```xml
   <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
   <uses-permission android:name="android.permission.INTERNET" />

   <application …>
       <activity android:name=".MainActivity" android:exported="true">
           <intent-filter>
               <action android:name="android.intent.action.MAIN" />
               <category android:name="android.intent.category.LAUNCHER" />
           </intent-filter>
       </activity>
   </application>
   ```

7. Run it, allow Nearby devices, paste your API key and tap **Save key**. Then press the badge button and ask something.

## Android-specific notes

- **One GATT operation at a time.** Android drops overlapping writes. `Z01Link` queues every write and descriptor write and starts the next one only from the callback.
- **MTU.** Android starts at 23 bytes. `Z01Link` asks for 247 before anything else, so frames go out in fewer pieces.
- **`TRANSPORT_LE`.** The badge is dual-mode. Connect GATT over LE explicitly, or Android may try the classic side, which is the speaker.
- **Opus.** `MediaCodec` needs an `OpusHead` as `csd-0`, plus the codec delay and seek pre-roll as `csd-1` and `csd-2`. It usually outputs 48 kHz, which `OpusDecoder` brings down to 16 kHz.

## Before you ship it

This sample keeps your API key on the phone, which is fine for your own device. In an app other people install, call Claude from your own server instead, so the key never ships inside the app.
