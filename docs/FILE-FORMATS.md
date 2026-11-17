# Z01 file formats

The files you can upload to the badge with the transfer in [PROTOCOL.md §13](PROTOCOL.md#13-uploading-a-file). Their CRCs are **CRC-16/XMODEM** (poly `1021`, init `0000`), the same as on the wire. Inside these files, every number is **little-endian**, CRCs included.

## Still picture: RU50 (`/VIE_xxx`)

A full-screen 360 × 360 picture. The stock app uploads wallpapers in this format, and GIFs too, as a single still.

```
0x000  fixed 60-byte header (below)
0x03C  crc16 of the 18 bytes at 0x03E…0x04F
0x03E  crc16 of the pixel data
0x040  format (4 bytes)
0x044  width (2)  height (2)            = 360, 360
0x048  pixel data size (4)
0x04C  pixel data offset (4)            = 0x450
0x050  1024 zero bytes
0x450  pixel data
```

Fixed header:

```
52 55 35 30 00 05 01 00 01 00 00 00 00 00 00 00
00 00 00 00 18 00 00 00 30 00 00 00 01 00 54 00
00 00 00 00 3C 00 00 00 01 00 50 00 00 00 00 00
00 01 00 00 50 00 00 00 00 04 00 00
```

There are two pixel formats. Use whichever comes out smaller:

### `01 00 90 00`: ETC2 RGBA8 (photos)

The picture as 90 × 90 blocks of 4 × 4 pixels, top-left first. Each block is 16 bytes: an 8-byte alpha block (`FF 00 00 00 00 00 00 00` = fully opaque), then an 8-byte ETC1 colour block (individual or differential mode). The pixel data is always 129,600 bytes.

### `01 80 20 00`: run-length tiles (flat pictures)

Lossless and much smaller for logos, text and flat colours.

- The picture is cut into 45 × 45 tiles of 8 × 8 pixels.
- First comes a table of 2025 `u32` values, one per tile: `offset | length << 22`, with the offset counted from the start of the table.
- Then each tile's packets. A pixel is 3 bytes: RGB565 (LE), then alpha.
  - `0x80 | n, pixel`: one pixel repeated `n` times
  - `n, pixel × n`: `n` different pixels

## Animation pack (`/AVI`)

The animations the badge plays on its own screens. It must always hold **exactly these seven names**: `1.avi` … `6.avi` and `s.avi` (the listening animation). A pack with missing names froze the badge when the wearer swiped onto an empty slot. Names can share the same video bytes.

The pack is a list of 32-byte records:

```
header:  crcSelf crcBody | 20 00 00 00 | packSize(4) | 03 FF 00 00 | name[16] = "AVI"
entry:   crcSelf crcData | offset(4) | size(4) | 02 FF | last(2) | name[16]
data:    index.idx, then the videos, each 16-byte aligned, padded with FF
```

- `crcSelf` covers bytes 2…31 of its own record.
- The header's `crcBody` covers everything after the header. An entry's `crcData` covers its file.
- `last` is `1` on the last entry, `0` on the others.
- Names end with `00` and are padded with `FF` up to 16 bytes.
- The first entry is `index.idx`:

```
"TIDX" | crc16(next 10 bytes) | FF × 6 | count(4)
then per name: crc16(rest) | length (= name length + 5) | number (from 1) | name | 00
```

## Animation video (inside the pack)

A motion-JPEG AVI, laid out like the badge's built-in faces:

- 360 × 360, **357/20 fps** (≈ 17.85 fps), 36 to 60 frames. Very short clips (one frame) can freeze the badge.
- One baseline JPEG per frame: 4:2:0, a single scan, no restart markers, no EXIF or JFIF metadata. The JPEGs iOS writes by default carry metadata and don't play.
- A PCM track, 8 kHz mono 16-bit (silence is fine), with two or three chunks of 186 samples after each frame.

```
RIFF 'AVI ' · LIST hdrl (avih, LIST strl (vids MJPG), LIST strl (auds PCM))
            · LIST movi ('00dc' jpeg, '01wb' pcm, …) · idx1
```
