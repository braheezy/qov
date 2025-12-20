# Phase 01: Foundation + Working Prototype

This phase establishes the core QOV data model, streaming encode/decode APIs, and a tiny CLI that roundtrips a small set of QOI frames through QOV. By the end, you can encode 3 QOI images into a QOV file and decode back to identical QOI images, proving the codec works end-to-end.

## Tasks

- [x] Create `src/qov.zig` with QOV constants, header/chunk structs, and error set (RGBA8 fixed-size frames only).
- [x] Implement streaming IO helpers in `src/qov.zig` using Zig’s reader/writer interfaces (read/write header, read/write chunk header + payload).
- [x] Implement I-frame encode/decode in `src/qov.zig` using QOI-style ops and end marker handling. (Added QOI-style encoder/decoder helpers plus roundtrip test with end-marker validation.)
- [x] Implement P-frame encode/decode in `src/qov.zig` with temporal ops (TRUN/TDIFF) plus spatial fallback ops. (Added encode/decode helpers with TRUN/TDIFF support and a roundtrip test.)
- [ ] Add `encodeStream` and `decodeStream` APIs in `src/qov.zig` that take a reader/writer and operate on in-memory RGBA8 frame buffers.
- [ ] Create `src/cli.zig` with `qov encode` (list of input .qoi paths -> .qov output) and `qov decode` (.qov -> output directory of .qoi files).
- [ ] Wire CLI into `build.zig` with `zig build run` support and install step.
- [ ] Add `src/qov_test.zig` with a 3-frame RGBA8 vector test: load 3 QOI files, encode to QOV in-memory, decode, and byte-compare RGBA outputs.
- [ ] Add a golden roundtrip CLI test script (or a Zig test) that encodes then decodes and verifies identical QOI output files.
- [ ] Verify: `zig build test` passes and `zig build run -- encode ...` then `decode ...` produces matching frames.
