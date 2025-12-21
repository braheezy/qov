# QOV - Quite Okay Video Format Specification

Version 1.0 (Draft)

## Overview

QOV is a simple, lossless video codec designed to fill the "triangle of neglect" in the video codec landscape - providing temporal compression with minimal complexity.

### Design Goals

1. **Simplicity**: ~1000 lines of code (compare: MJPEG ~300, MPEG-2 ~5000, H.264 ~50,000)
2. **Lossless**: No quality degradation, matching QOI's spirit
3. **Temporal compression**: Better than MJPEG's frame-by-frame approach
4. **Integrated audio**: Native QOA audio support
5. **Playable**: Must work with SDL for real-time playback

### Target Use Cases

- Screen recording and UI capture (lots of static regions)
- Animations (e.g., Bad Apple)
- Moderate motion content
- NOT optimized for high-motion natural video (use H.264/etc for that)

### Expected Performance

| Content Type       | 1080p30 Bitrate | vs MJPEG |
|--------------------|-----------------|----------|
| Static (slides)    | 15-30 Mbps      | 3-5x better |
| Moderate motion    | 50-100 Mbps     | 2-3x better |
| High motion        | 100-200 Mbps    | 1.5-2x better |

---

## The Video Codec Landscape

QOV aims for: **~1000 LOC, 30-80 Mbps for 1080p30**

Position in the landscape:
- Raw: 0 LOC, ~1500 Mbps
- MJPEG: ~300 LOC, 50-100 Mbps  
- **QOV: ~1000 LOC, 30-80 Mbps** <-- Target
- MPEG-2: ~5000 LOC, 8-15 Mbps
- H.264: ~50,000 LOC, 3-8 Mbps

---

## File Format

### Overall Structure

```
+----------------+
|  File Header   |  32 bytes
+----------------+
|    Chunk 0     |  5-byte header + payload
+----------------+
|    Chunk 1     |
+----------------+
|      ...       |
+----------------+
|    Chunk N     |
+----------------+
```

### File Header (32 bytes)

| Offset | Size | Type    | Description |
|--------|------|---------|-------------|
| 0      | 4    | char[4] | Magic: "qovf" (0x71 0x6F 0x76 0x66) |
| 4      | 1    | u8      | Version (currently 1) |
| 5      | 2    | u16 BE  | Width in pixels |
| 7      | 2    | u16 BE  | Height in pixels |
| 9      | 2    | u16 BE  | Frame rate numerator |
| 11     | 2    | u16 BE  | Frame rate denominator |
| 13     | 1    | u8      | Colorspace: 0=sRGB, 1=linear |
| 14     | 1    | u8      | Channels: 3=RGB, 4=RGBA |
| 15     | 1    | u8      | GOP size (I-frame interval) |
| 16     | 1    | u8      | Has audio: 0=no, 1=yes |
| 17     | 3    | u24 BE  | Audio sample rate |
| 20     | 1    | u8      | Audio channels |
| 21     | 4    | u32 BE  | Total frame count (0=streaming) |
| 25     | 1    | u8      | Flags (bit 0 = RGB-only, alpha implicit 255; bit 1 = per-frame duration metadata in chunk headers) |
| 26     | 6    | -       | Reserved (set to 0) |

### Chunk Header (5 bytes)

| Offset | Size | Type   | Description |
|--------|------|--------|-------------|
| 0      | 1    | u8     | Chunk type: 0=I-frame, 1=P-frame, 2=Audio |
| 1      | 4    | u32 BE | Payload size in bytes |

If header flag bit 1 is set, each chunk header is extended with an extra 4 bytes:

| Offset | Size | Type   | Description |
|--------|------|--------|-------------|
| 5      | 4    | u32 BE | Frame duration in microseconds |

### Video Frame Payload

Encoded as a sequence of op-codes, ending with 8-byte marker:
`0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x01`

### Audio Frame Payload

Raw QOA frame data (self-describing with own headers).

---

## Op-Code Encoding

### Summary Table

| Op-Code | Byte Pattern      | Size    | Description                    |
|---------|-------------------|---------|--------------------------------|
| INDEX   | `00iiiiii`        | 1 byte  | Color from 64-entry cache      |
| DIFF    | `01rrggbb`        | 1 byte  | Small RGB delta (-2 to +1)     |
| LUMA    | `10gggggg` + byte | 2 bytes | Green-biased delta             |
| RUN     | `11nnnnnn`        | 1 byte  | Spatial run 1-62 pixels        |
| RGB     | `0xFE` + RGB      | 4 bytes | Literal RGB value              |
| RGBA    | `0xFF` + RGBA     | 5 bytes | Literal RGBA value             |
| TRUN    | `0xFC` + byte     | 2 bytes | Temporal run 1-256 pixels      |
| TDIFF   | `0xFD` + byte     | 2 bytes | Temporal delta                 |

### Spatial Ops (from QOI)

#### INDEX (1 byte): `00iiiiii`
- 6-bit index into 64-entry color cache
- Hash: `index = (r * 3 + g * 5 + b * 7 + a * 11) % 64`

#### DIFF (1 byte): `01rrggbb`
- 2-bit deltas per channel, bias -2 (range -2 to +1)
- Decode: `new = prev + (encoded - 2)`

#### LUMA (2 bytes): `10gggggg` + `rrrrbbbb`
- Byte 0: 6-bit green delta, bias -32 (range -32 to +31)
- Byte 1: 4-bit dr-dg (bias -8), 4-bit db-dg (bias -8)
- Decode: `dg = byte0 - 32; dr = (byte1 >> 4) - 8 + dg; db = (byte1 & 0xF) - 8 + dg`

#### RUN (1 byte): `11nnnnnn`
- 6-bit count minus 1 (range 1-62 pixels)
- Values 62-63 reserved for special ops

#### RGB (4 bytes): `0xFE r g b`
- Literal RGB, alpha unchanged

#### RGBA (5 bytes): `0xFF r g b a`
- Literal RGBA

### Temporal Ops (P-frames only)

#### TRUN (2 bytes): `0xFC n`
- n+1 pixels unchanged from previous frame (range 1-256)

#### TDIFF (2 bytes): `0xFD srrggbb0`
- s = sign bit (0=positive, 1=negative)
- rr, gg, bb = 2-bit deltas (range 0-3)
- When s=0: delta = +encoded; when s=1: delta = -encoded

---

## Decoder State

```
color_cache: [64]RGBA      // Same as QOI
prev_pixel: RGBA           // Previous pixel in scanline
prev_frame: []RGBA         // Previous frame buffer (P-frames)
x, y: u32                  // Current position
```

### Initialization (per frame)
- prev_pixel = RGBA(0, 0, 0, 255)
- color_cache = all zeros
- x = 0, y = 0

### Decode Loop Pseudocode

```
while not end_of_frame:
    byte = read_byte()
    
    if byte == 0xFE:        pixel = read_rgb()
    elif byte == 0xFF:      pixel = read_rgba()
    elif byte == 0xFC:      # TRUN
        count = read_byte() + 1
        copy count pixels from prev_frame
        continue
    elif byte == 0xFD:      # TDIFF
        pixel = prev_frame[pos] + decode_tdiff(read_byte())
    elif byte >> 6 == 0b00: pixel = color_cache[byte & 0x3F]
    elif byte >> 6 == 0b01: pixel = prev_pixel + decode_diff(byte)
    elif byte >> 6 == 0b10: pixel = prev_pixel + decode_luma(byte, read_byte())
    elif byte >> 6 == 0b11: # RUN
        count = (byte & 0x3F) + 1
        output prev_pixel count times
        continue
    
    color_cache[hash(pixel)] = pixel
    prev_pixel = pixel
    output(pixel)
```

---

## Encoder Algorithm

### I-Frame (pure QOI)

```
for each pixel:
    if pixel == prev_pixel:
        run_length++
        if run_length == 62: emit RUN, reset
    else:
        flush any pending run
        if cache[hash(pixel)] == pixel: emit INDEX
        elif can_diff(pixel, prev): emit DIFF
        elif can_luma(pixel, prev): emit LUMA  
        elif alpha unchanged: emit RGB
        else: emit RGBA
        
        cache[hash(pixel)] = pixel
        prev_pixel = pixel

emit end_marker
```

### P-Frame (temporal + spatial)

```
for i, pixel in pixels:
    temporal = prev_frame[i]
    
    if pixel == temporal:
        trun_length++
        if trun_length == 256: emit TRUN, reset
    else:
        flush any pending TRUN
        if can_tdiff(pixel, temporal): emit TDIFF
        else: # fall back to spatial ops
            ... (same as I-frame logic)

emit end_marker
```

### Encoder Decision Order

**P-frames:** TRUN > TDIFF > INDEX > DIFF > LUMA > RGB > RGBA

**I-frames:** RUN > INDEX > DIFF > LUMA > RGB > RGBA

---

## GOP Structure

```
I P P P P P P P P P P P P P P I P P P ...
|<-------- GOP size -------->|
```

- GOP size in header (typically 30 = 1 sec at 30fps)
- Every GOP starts with I-frame for seeking
- All other frames are P-frames

---

## Audio/Video Interleaving

```
[Video I-frame 0]
[Audio chunk(s)]
[Video P-frame 1]
[Audio chunk(s)]
...
```

QOA frame = 5120 samples = 106.7ms at 48kHz
Video frame = 33.3ms at 30fps
Roughly 1 audio chunk per 3 video frames.

---

## Reference Implementation

### Files to Study

1. `zigimg/src/formats/qoi.zig` - QOI encoder/decoder, color cache, hash
2. `zigaudio/src/qoa.zig` - Frame streaming, audio frame structure  
3. `zmpeg/src/video.zig` - Frame buffer management

### Implementation Phases

| Phase | Component               | Est. LOC |
|-------|-------------------------|----------|
| 1     | Core types, headers     | 100      |
| 2     | I-frame decoder         | 150      |
| 3     | I-frame encoder         | 150      |
| 4     | P-frame decoder         | 100      |
| 5     | P-frame encoder         | 150      |
| 6     | Container/chunks        | 100      |
| 7     | Audio interleaving      | 50       |
| 8     | Tests                   | 100      |
| **Total** |                     | **~900** |

### Project Structure

```
qov/
  src/
    qov.zig          # Main codec
    qov_test.zig     # Tests
  examples/
    encode.zig       # Image sequence -> QOV
    decode.zig       # QOV -> image sequence
    player.zig       # SDL2 player
  build.zig
  SPEC.md
  README.md
```

---

## Test Vectors

### Minimal: 2x2, 2 frames

Frame 0 (I): Red, Green, Blue, White
Frame 1 (P): Red, Green, Blue, Black (white->black change)

Expected P-frame: TRUN(3) + RGB/DIFF for black

### Bad Apple Test

Black/white animation with lots of static regions.
Should achieve excellent compression via TRUN.

---

## Appendix: Byte Example

### 4x2, 2 frames, no audio

```
Header (32 bytes):
71 6F 76 66  magic "qovf"
01           version 1
00 04        width 4
00 02        height 2
00 1E        fps num 30
00 01        fps den 1
00           sRGB
03           RGB
1E           GOP 30
00           no audio
00 00 00     audio rate 0
00           audio ch 0
00 00 00 02  2 frames
00 00 00 00 00 00 00  reserved

Chunk 0 (I-frame):
00           type I
00 00 00 XX  size
[pixel ops]
00 00 00 00 00 00 00 01  end

Chunk 1 (P-frame):
01           type P
00 00 00 XX  size
[pixel ops]  
00 00 00 00 00 00 00 01  end
```

---

## Comparison

| Aspect     | QOV      | QOI      | QOA      | MJPEG    |
|------------|----------|----------|----------|----------|
| Type       | Video    | Image    | Audio    | Video    |
| Lossless   | Yes      | Yes      | No       | No       |
| Temporal   | Yes      | No       | No       | No       |
| LOC        | ~900     | ~400     | ~600     | ~300     |
| Ratio      | 10-50:1  | 3-4:1    | 5:1      | 10-20:1  |

---

## Revision History

- v1.0 (Draft): Initial specification
