# How we replaced the Z01's brain with Claude

This is the story in plain words. The byte-level details are in [PROTOCOL.md](PROTOCOL.md).

## The badge was never smart

The Z01 looks like an AI gadget, but nothing in it thinks. Inside there's a microphone, a speaker, a small round screen, a button and a Bluetooth chip. It's the same kind of chip you'll find in a cheap smartwatch or in no-name earbuds.

The "AI" lived somewhere else. The stock app on your phone did this:

```
badge mic ──▶ phone app ──▶ the vendor's cloud AI ──▶ phone app ──▶ badge screen
```

The badge records you, the app sends that to a server, and the answer comes back down to the screen. Everything clever happens off the badge.

That means if we could speak the badge's Bluetooth language ourselves, we could take the middle part out and put any AI there. That's what we did.

## Step 1: listen to the conversation

iPhones can record every Bluetooth packet they send and receive (Apple's PacketLogger, with a Bluetooth logging profile). We recorded the stock app while it connected, while we pressed the button and spoke, while it showed an answer and while it uploaded a wallpaper.

Two things stood out:

- The messages started with `FE DC BA` and ended with `EF`. That's the signature of **RCSP**, the protocol JieLi (the chip maker) uses in lots of its products. So we weren't starting from zero: the frame layout was a known shape.
- Screen text went on a separate channel and started with `88 88 11`. It was readable: the UTF-8 text was right there, two characters at a time.

## Step 2: get past the lock

The badge refuses commands until the app passes a challenge. It sends 16 random bytes, and the app must answer with those bytes scrambled by a secret JieLi function.

We don't know that function. But the check runs both ways: the app challenges the badge too, and the badge happily scrambles any 16 bytes it's given. So when the badge challenges us, we send its own challenge straight back to it as our challenge. It scrambles it and gives us the answer, and we hand that answer back as ours. The badge has unlocked itself.

That's the whole trick. No keys, no firmware changes. [PROTOCOL.md §4](PROTOCOL.md#4-authentication-the-reflection-trick) shows the exact exchange.

## Step 3: hear what the badge hears

When the app sends one command (`04`), the badge starts streaming its microphone over Bluetooth. Each little packet holds four slices of sound, 20 ms each. The slices are **Opus**, the open voice codec most calling apps use, at 16 kHz mono. Decode them and you hear what the badge heard.

From there it's ordinary phone work: give the sound to a speech recognizer (Apple's is built in) and you have text.

## Step 4: put the answer on the screen

Text goes on the vendor channel: a short header, then two characters per message. The badge acks each one, and if you send too fast it drops some. The stock app waits about 120 ms between messages, so we do too.

We also learned the badge's own screens (listening, thinking, replying), which you switch with one short command. That's enough to make the badge feel alive while the AI works.

## Step 5: let it talk

This part turned out to be the easiest. The Z01 is also an ordinary Bluetooth speaker. The phone lists it as an audio output called `Z01`. Choose it, and anything the app says with text-to-speech comes out of the badge.

## Step 6: swap in Claude

With all of that, the stock app's loop has a hole exactly where the AI goes:

```
badge mic ──▶ your app ──▶ Claude ──▶ your app ──▶ badge screen + badge speaker
   (Opus)      (speech      (your API      (2 characters     (Bluetooth
               to text)     key, your      per frame)        audio)
                            prompt, your
                            tools)
```

Our app sends what you said to the Claude API, streams the answer back and shows it on the badge as it arrives, so you don't wait for the whole answer. Then it reads the answer out through the badge speaker.

Because it's our app now, Claude can do more than chat. In our own apps the same badge sends email, reads the calendar, plays music, gives turn-by-turn directions on the screen and types for you. Each of those is just a tool you give to Claude.

## Step 7: the details that took the longest

None of these show up in a capture. We found them by testing on real badges:

- **The QR code.** Press the side button without opening the mic, and the badge shows the stock app's "App not connected" QR code, even though you're connected. Opening the mic for at least two seconds after a press keeps it away.
- **The animation pack** must always hold all seven animations. Leave one out, and the badge freezes when the wearer swipes onto the empty slot.
- **One-frame videos** can lock the badge up, so animations are at least about two seconds long.
- **Emoji** can't be drawn by the badge's font, so they're stripped before sending.

## What we didn't touch

We never modified the firmware, never extracted keys and never broke encryption. The badge runs exactly as it shipped. We only taught a new app to speak its language, which is the same thing the stock app does.
