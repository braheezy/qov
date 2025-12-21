# Phase 03: Format Expansion + Polish

This phase expands codec capabilities, improves interoperability, and adds developer quality-of-life improvements.

## Tasks

- [x] Add optional RGB-only support (treat alpha as 255) with explicit flags in header. (Added header flag, RGB frame handling in codec/CLI, and tests.)
- [x] Add frame metadata support (timestamps or frame durations) in chunk headers. (Added frame_metadata header flag, optional u32 microsecond duration in chunk headers, decoder tracking, and tests.)
- [x] Implement optional parallel encode of frames (per-frame preprocessing) while preserving stream order. (Added parallel encode path with thread pool fallback, and tests.)
- [x] Add a `qov info` CLI subcommand to print header and frame metadata. (Added info command with header/frame listing and tests.)
- [x] Add doc comments and usage examples to `src/qov.zig` and `src/cli.zig` for API clarity. (Added module/API docs plus CLI usage examples and a CLI info output test.)
- [x] Add a small sample project in `examples/` demonstrating in-memory encode/decode. (Added `examples/in-memory` Zig project, README, and an in-memory encode/decode test.)
