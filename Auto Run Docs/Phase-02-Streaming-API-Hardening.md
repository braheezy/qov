# Phase 02: Streaming API + Hardening

This phase tightens streaming ergonomics, improves error handling, and expands tests to cover edge cases and limits, making the codec reliable for larger sequences.

## Tasks

- [x] Add explicit streaming frame iteration helpers (e.g., `nextFrame()` decoder state machine) in `src/qov.zig`.
  - Added `StreamDecoder` with `nextFrame` and refactored `decodeStream` to use it; covered by a new helper test in `src/qov.zig`.
- [x] Validate and enforce fixed width/height across frames with clear error messages.
  - Added a dedicated `FrameSizeMismatch` error surfaced by stream encode/decode checks and covered by a new stream mismatch test.
- [x] Add tests for RUN/TRUN boundary lengths, chunk payload sizing, and end marker detection in `src/qov_test.zig`.
  - Added I-frame RUN and P-frame TRUN boundary coverage, verified chunk payload sizing against encoded payloads, and asserted end marker detection failures in `src/qov_test.zig`.
- [x] Add negative tests for malformed headers, unknown chunk types, and truncated streams.
  - Added malformed header coverage (bad magic/version/fields, truncated header), unknown chunk type parsing failure, and truncated stream decode error tests in `src/qov_test.zig`.
- [x] Add frame-count streaming behavior: support `frame_count = 0` (unknown) and ensure decode ends on EOF.
- [x] Improve CLI validation and error messages for mismatched frame sizes or invalid QOI inputs.
  - Added CLI stderr messaging for QOI decode failures and frame size mismatches, plus small helper tests for message formatting in `src/cli.zig`.
- [ ] Benchmark a small multi-frame encode/decode in tests to guard performance regressions.
