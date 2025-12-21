# Audio Stream Tasks (QOA)

Goal: add QOA audio streams to QOV, reusing/adapting `qoa.zig`, and play audio with SDL.

## Tasks

- [x] Review `qoa.zig` and extract minimal decode helpers for streaming PCM (target: f32 or s16) with frame-by-frame access. Added `src/qoa_stream.zig` with frame header parsing, s16/f32 decode helpers, and basic tests using `arcade.qoa`.
- [ ] Define QOV audio chunk payload format and header fields (sample rate, channels, frames per chunk) in `src/qov.zig`.
- [ ] Implement audio chunk encode/decode helpers in `src/qov.zig` (read/write chunk headers + payload validation).
- [ ] Extend `encodeStream` to optionally interleave audio chunks with video frames; decide mapping (e.g., 1 audio chunk per video frame or time-based chunking).
- [ ] Extend `StreamDecoder` to expose audio frames (new `nextAudio()` or unified `nextPacket()` with tag) and validate audio metadata.
- [ ] Update CLI `qov encode` to accept a `.qoa` file (e.g., `--audio arcade.qoa`) and store audio metadata in the header.
- [ ] Update CLI `qov decode` to optionally dump audio chunks to `.qoa` or raw PCM for verification.
- [ ] Update SDL player to open an audio device, queue decoded PCM, and keep A/V in sync (tolerate longer audio than video).
- [ ] Add tests in `src/qov_test.zig` for audio header validation, chunk read/write, and end-of-stream behavior.
- [ ] Add a small end-to-end script/test using `arcade.qoa` to ensure encode/decode/playback works and handles audio longer than video.
