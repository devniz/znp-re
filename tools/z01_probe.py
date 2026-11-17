#!/usr/bin/env python3
"""Talk to a ZNP Z01 badge from your computer: the fastest way to check the protocol.

    pip install bleak
    python3 tools/z01_probe.py                     # connect, unlock, print the battery
    python3 tools/z01_probe.py --text "Hello!"     # show text on the badge
    python3 tools/z01_probe.py --screen thinking   # switch screens
    python3 tools/z01_probe.py --listen            # press the badge button and talk

--listen saves each utterance's raw Opus packets to z01-<time>.opus-packets
(each packet prefixed with its length as 2 bytes, big-endian). With `pip install
opuslib` (and libopus on the system) it also writes a playable .wav.

Close the stock app first: only one app can hold the badge.
See docs/PROTOCOL.md for every byte used here.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner


def uuid(short: str) -> str:
    return f"0000{short}-0000-1000-8000-00805f9b34fb"


RCSP_WRITE, RCSP_NOTIFY = uuid("ae01"), uuid("ae02")
TEXT_WRITE, TEXT_NOTIFY = uuid("df98"), uuid("df99")
PASS = b"\x02pass"
TEXT_ACK = bytes.fromhex("888811020100")
SCREENS = {"replying": 0x02, "listening": 0x03, "thinking": 0x04}


# --- RCSP frames (PROTOCOL.md §5) -------------------------------------------

def encode(flag: int, opcode: int, params: bytes) -> bytes:
    return b"\xfe\xdc\xba" + bytes([flag, opcode]) + len(params).to_bytes(2, "big") + params + b"\xef"


def parse(b: bytes):
    """(flag, opcode, params) or None if `b` isn't one whole frame."""
    if len(b) < 8 or b[:3] != b"\xfe\xdc\xba" or b[-1] != 0xEF:
        return None
    n = int.from_bytes(b[5:7], "big")
    if len(b) != 8 + n:
        return None
    return b[3], b[4], b[7:7 + n]


def text_frame(chars: str) -> bytes:
    """PROTOCOL.md §9: 88 88 11 01 | n+5 | 00 n 00 00 n | UTF-8."""
    t = chars.encode()[:250]
    n = len(t)
    return bytes([0x88, 0x88, 0x11, 0x01, n + 5, 0x00, n, 0x00, 0x00, n]) + t


class Z01:
    def __init__(self, client: BleakClient):
        self.client = client
        self.sn = 0
        self.ready = asyncio.Event()
        self.auth_state = "idle"
        self.text_ack = asyncio.Event()
        self.on_button = None
        self.mic_open = False
        self.packets: list[bytes] = []
        self.battery = asyncio.Future()

    # Writing ---------------------------------------------------------------

    async def write(self, data: bytes, char: str):
        c = self.client.services.get_characteristic(char)
        without = "write-without-response" in c.properties
        size = max(20, (self.client.mtu_size or 23) - 3)
        for i in range(0, len(data), size):  # the badge joins the pieces
            await self.client.write_gatt_char(c, data[i:i + size], response=not without)

    async def command(self, opcode: int, data: bytes, flag: int = 0xC0) -> int:
        self.sn = (self.sn + 1) & 0xFF
        await self.write(encode(flag, opcode, bytes([self.sn]) + data), RCSP_WRITE)
        return self.sn

    # Incoming --------------------------------------------------------------

    def on_rcsp(self, _sender, raw: bytearray):
        raw = bytes(raw)
        frame = parse(raw)
        if frame is None:
            asyncio.ensure_future(self.on_auth(raw))
            return
        flag, opcode, params = frame
        is_command = bool(flag & 0x80)
        data = params[1:] if is_command else params[2:]
        if is_command and opcode == 0x01 and data and data[0] > 0:
            if self.mic_open:  # count + equal-size Opus packets (PROTOCOL.md §10)
                count, body = data[0], data[1:]
                size = len(body) // count
                self.packets += [body[i * size:(i + 1) * size] for i in range(count)]
        elif is_command and opcode == 0xFF and data == b"\xff\xf7\xf1\x00":
            print("• button pressed")
            if self.on_button:
                asyncio.ensure_future(self.on_button())
        elif is_command and opcode == 0xFF and data == b"\xff\xf7\xf1\x01":
            print("• session ended on the badge")
        elif not is_command and opcode == 0x03 and params[:1] == b"\x00":
            if not self.battery.done() and len(data) >= 3 and data[1] == 0x01:
                self.battery.set_result(data[2])
        elif not is_command and opcode == 0x04:
            print("• mic open" if params[:1] == b"\x00" else "• the badge refused the mic")

    def on_text(self, _sender, raw: bytearray):
        if bytes(raw) == TEXT_ACK:
            self.text_ack.set()

    async def on_auth(self, b: bytes):
        """The reflection trick (PROTOCOL.md §4)."""
        if not b:
            return
        if b[0] == 0x01 and self.auth_state == "challenged":
            self.auth_state = "passed"
            await self.write(PASS, RCSP_WRITE)
        elif b[0] == 0x01 and self.auth_state == "reflecting":
            self.auth_state = "responded"
            await self.write(b, RCSP_WRITE)  # its answer to its own challenge is ours
        elif b[0] == 0x00:
            self.auth_state = "reflecting"
            await self.write(b, RCSP_WRITE)  # send the badge's challenge straight back
        elif b == PASS and self.auth_state in ("passed", "responded"):
            self.ready.set()

    # Steps -----------------------------------------------------------------

    async def unlock(self):
        await self.client.start_notify(TEXT_NOTIFY, self.on_text)
        await self.client.start_notify(RCSP_NOTIFY, self.on_rcsp)
        await asyncio.sleep(0.5)
        self.auth_state = "challenged"
        await self.write(b"\x00" + os.urandom(16), RCSP_WRITE)
        await asyncio.wait_for(self.ready.wait(), 10)
        t = time.localtime()
        await self.command(0x08, bytes([0x02, 0x08, 0x00]) + t.tm_year.to_bytes(2, "big")
                           + bytes([t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec]))
        await self.command(0x03, b"\xff\xff\xff\xff")

    async def screen(self, name: str):
        await self.command(0xFF, bytes([0xFF, 0xF7, 0xF1, SCREENS[name]]), flag=0x80)

    async def show_text(self, text: str):
        await self.screen("replying")
        chars = list(" ".join(text.split()))
        for i in range(0, len(chars), 2):
            self.text_ack.clear()
            await self.write(text_frame("".join(chars[i:i + 2])), TEXT_WRITE)
            try:
                await asyncio.wait_for(self.text_ack.wait(), 0.35)
            except asyncio.TimeoutError:
                pass
            await asyncio.sleep(0.12)

    async def record(self, seconds: float):
        self.packets = []
        self.mic_open = True
        await self.command(0x04, b"\x02\x10\x00")
        await asyncio.sleep(max(2.0, seconds))  # ≥ 2 s after a press keeps the QR code away
        self.mic_open = False
        await self.command(0x05, b"\x00")
        await self.screen("thinking")
        save(self.packets)


def save(packets: list[bytes]):
    stamp = time.strftime("%H%M%S")
    path = f"z01-{stamp}.opus-packets"
    with open(path, "wb") as f:
        for p in packets:
            f.write(struct.pack(">H", len(p)) + p)
    print(f"  {len(packets)} packets ({len(packets) * 20 / 1000:.1f} s) → {path}")
    try:
        import opuslib
    except Exception:
        print("  (pip install opuslib for a .wav too)")
        return
    decoder = opuslib.Decoder(16000, 1)
    with wave.open(f"z01-{stamp}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        for p in packets:
            w.writeframes(decoder.decode(p, 320))
    print(f"  → z01-{stamp}.wav")


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--text", help="show this text on the badge")
    parser.add_argument("--screen", choices=SCREENS, help="switch to one of the firmware screens")
    parser.add_argument("--listen", action="store_true", help="record after each button press")
    parser.add_argument("--seconds", type=float, default=4, help="how long to record per press (default 4)")
    args = parser.parse_args()

    print("Looking for a Z01…")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or ad.local_name or "").startswith("Z01"), timeout=15)
    if device is None:
        sys.exit("No Z01 found. Is it on, and is the stock app closed?")

    async with BleakClient(device) as client:
        badge = Z01(client)
        print(f"Connected to {device.name}. Unlocking…")
        await badge.unlock()
        try:
            print(f"Ready. Battery: {await asyncio.wait_for(badge.battery, 3)} %")
        except asyncio.TimeoutError:
            print("Ready.")

        if args.screen:
            await badge.screen(args.screen)
        if args.text:
            await badge.show_text(args.text)
        if args.listen:
            badge.on_button = lambda: badge.record(args.seconds)
            print("Press the badge button and talk. Ctrl-C to stop.")
            while True:
                await asyncio.sleep(1)
        await asyncio.sleep(0.5)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
