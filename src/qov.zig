/// QOV container encode/decode helpers for in-memory frame streams.
/// Example:
/// ```
/// const std = @import("std");
/// const qov = @import("qov");
///
/// var gpa = std.heap.DebugAllocator(.{}){};
/// defer _ = gpa.deinit();
/// const allocator = gpa.allocator();
///
/// const frame0 = [_]u8{ 0x00, 0x00, 0x00, 0xFF };
/// const frames = [_][]const u8{ &frame0 };
///
/// const header = qov.Header{
///     .width = 1,
///     .height = 1,
///     .fps_num = 30,
///     .fps_den = 1,
///     .colorspace = .srgb,
///     .channels = .rgba,
///     .gop_size = 1,
///     .has_audio = false,
///     .audio_sample_rate = 0,
///     .audio_channels = 0,
///     .audio_frames_per_chunk = 0,
///     .frame_count = 1,
/// };
///
/// var encoded = std.ArrayList(u8).empty;
/// defer encoded.deinit(allocator);
/// var writer = encoded.writer(allocator);
/// try qov.encodeStream(allocator, &writer, header, &frames, null);
///
/// var reader: std.Io.Reader = .fixed(encoded.items);
/// var out_frame: [4]u8 = undefined;
/// var out_frames = [_][]u8{ &out_frame };
/// _ = try qov.decodeStream(allocator, &reader, &out_frames);
/// ```
const std = @import("std");
const builtin = @import("builtin");
const qoa_stream = @import("qoa_stream.zig");

fn writerErrorType(comptime WriterType: type) type {
    return switch (@typeInfo(WriterType)) {
        .pointer => @typeInfo(WriterType).pointer.child.Error,
        else => WriterType.Error,
    };
}

fn readerErrorType(comptime ReaderType: type) type {
    return switch (@typeInfo(ReaderType)) {
        .pointer => @typeInfo(ReaderType).pointer.child.Error,
        else => ReaderType.Error,
    };
}

/// Magic bytes used at the start of every QOV stream.
pub const magic = [4]u8{ 'q', 'o', 'v', 'f' };
/// Stream format version.
pub const version: u8 = 1;

/// Serialized header size in bytes.
pub const header_size: usize = 32;
/// Serialized chunk header size without per-frame metadata.
pub const chunk_header_size: usize = 5;
/// Serialized chunk header size with per-frame duration metadata.
pub const chunk_header_metadata_size: usize = chunk_header_size + 4;
/// End marker used by the QOV payload encoder.
pub const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
/// Header flag that marks a stream as RGB-only (alpha implied 0xFF).
pub const header_flag_rgb_only: u8 = 1 << 0;
/// Header flag that enables per-frame duration metadata.
pub const header_flag_frame_metadata: u8 = 1 << 1;

/// Supported colorspaces for QOV frames.
pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

/// Supported channel layouts for QOV frames.
pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

/// Packed header flags stored in the stream header.
pub const HeaderFlags = packed struct(u8) {
    rgb_only: bool = false,
    frame_metadata: bool = false,
    _reserved: u6 = 0,
};

/// Chunk types stored in the stream.
pub const ChunkType = enum(u8) {
    iframe = 0,
    pframe = 1,
    audio = 2,
};

/// Audio chunk payloads are a concatenation of QOA frames. Each frame includes the
/// 8-byte QOA header (channels, sample rate, frame length, frame size) followed by
/// the frame payload. The number of frames per chunk is stored in the stream header.

/// Stream header describing frame geometry and codec settings.
pub const Header = struct {
    width: u16,
    height: u16,
    fps_num: u16,
    fps_den: u16,
    colorspace: Colorspace,
    channels: Channels,
    flags: HeaderFlags = .{},
    gop_size: u8,
    has_audio: bool,
    audio_sample_rate: u32,
    audio_channels: u8,
    audio_frames_per_chunk: u16,
    frame_count: u32,
};

/// Options for encoding, including optional parallel preprocessing.
pub const EncodeOptions = struct {
    parallel: bool = false,
    max_threads: ?usize = null,
    /// Optional audio chunk payloads to interleave with video frames.
    /// Mapping: one audio chunk is written after each video frame, then any
    /// remaining audio chunks are appended at the end of the stream.
    audio_chunks: ?[]const []const u8 = null,
};

/// Chunk header describing the payload and optional duration metadata.
pub const ChunkHeader = struct {
    chunk_type: ChunkType,
    payload_size: u32,
    frame_duration_us: u32 = 0,
};

/// Errors returned by QOV parsing and encoding helpers.
pub const QovError = error{
    InvalidMagic,
    UnsupportedVersion,
    UnsupportedChannels,
    UnsupportedColorspace,
    UnsupportedAudio,
    InvalidHeader,
    InvalidChunk,
    FrameSizeMismatch,
    UnexpectedEof,
};

pub const QoaFrameHeader = qoa_stream.FrameHeader;
pub const QoaFrameDecoder = qoa_stream.FrameDecoder;
pub const qoaMaxSamplesPerFrame = qoa_stream.maxSamplesPerFrame;

pub fn parseQoaFrameHeader(bytes: []const u8) !qoa_stream.FrameHeader {
    return qoa_stream.parseFrameHeader(bytes);
}

/// Returns true when the header declares audio streams.
pub fn hasAudio(header: Header) bool {
    return header.has_audio;
}

/// Returns true when the header declares RGBA frames.
pub fn isRgba(header: Header) bool {
    return header.channels == .rgba;
}

/// Returns true when the stream treats alpha as 0xFF.
pub fn isRgbOnly(header: Header) bool {
    return header.flags.rgb_only;
}

/// Returns the number of pixels in each frame.
pub fn headerFramePixels(header: Header) usize {
    return @as(usize, header.width) * @as(usize, header.height);
}

/// Returns the number of bytes per frame for the header layout.
pub fn headerFrameBytes(header: Header) usize {
    const bytes_per_pixel: usize = if (header.flags.rgb_only) 3 else 4;
    return headerFramePixels(header) * bytes_per_pixel;
}

/// Validates header fields and flags for encoding/decoding.
pub fn validateHeader(header: Header) QovError!void {
    if (header.flags._reserved != 0) return QovError.InvalidHeader;
    if (header.flags.rgb_only) {
        if (header.channels != .rgb) return QovError.InvalidHeader;
    } else {
        if (header.channels != .rgba) return QovError.UnsupportedChannels;
    }
    if (header.has_audio) {
        if (header.audio_sample_rate == 0) return QovError.InvalidHeader;
        if (header.audio_sample_rate > 0xFFFFFF) return QovError.InvalidHeader;
        if (header.audio_channels == 0) return QovError.InvalidHeader;
        if (header.audio_frames_per_chunk == 0) return QovError.InvalidHeader;
    } else {
        if (header.audio_sample_rate != 0) return QovError.InvalidHeader;
        if (header.audio_channels != 0) return QovError.InvalidHeader;
        if (header.audio_frames_per_chunk != 0) return QovError.InvalidHeader;
    }
    if (header.fps_num == 0) return QovError.InvalidHeader;
    if (header.fps_den == 0) return QovError.InvalidHeader;
    if (header.width == 0 or header.height == 0) return QovError.InvalidHeader;
}

/// Converts a serialized chunk type byte into a ChunkType.
pub fn chunkTypeFromByte(byte: u8) QovError!ChunkType {
    return switch (byte) {
        0 => .iframe,
        1 => .pframe,
        2 => .audio,
        else => QovError.InvalidChunk,
    };
}

/// Converts a serialized colorspace byte into a Colorspace.
pub fn colorspaceFromByte(byte: u8) QovError!Colorspace {
    return switch (byte) {
        0 => .srgb,
        1 => .linear,
        else => QovError.UnsupportedColorspace,
    };
}

/// Converts a serialized channel byte into a Channels enum.
pub fn channelsFromByte(byte: u8) QovError!Channels {
    return switch (byte) {
        3 => .rgb,
        4 => .rgba,
        else => QovError.UnsupportedChannels,
    };
}

/// Serializes a Channels value into a byte.
pub fn channelByte(channels: Channels) u8 {
    return @intFromEnum(channels);
}

/// Serializes a Colorspace value into a byte.
pub fn colorspaceByte(colorspace: Colorspace) u8 {
    return @intFromEnum(colorspace);
}

/// Serializes a ChunkType value into a byte.
pub fn chunkTypeByte(chunk_type: ChunkType) u8 {
    return @intFromEnum(chunk_type);
}

/// Returns the serialized header size based on metadata availability.
pub fn chunkHeaderSize(has_metadata: bool) usize {
    return if (has_metadata) chunk_header_metadata_size else chunk_header_size;
}

fn readExact(reader: anytype, buf: []u8) (QovError || readerErrorType(@TypeOf(reader)))!void {
    const ReaderT = switch (@typeInfo(@TypeOf(reader))) {
        .pointer => |ptr_info| ptr_info.child,
        else => @TypeOf(reader),
    };
    if (@hasDecl(ReaderT, "readSliceAll")) {
        reader.readSliceAll(buf) catch |err| switch (err) {
            error.EndOfStream => return QovError.UnexpectedEof,
            else => |e| return e,
        };
        return;
    }
    if (@hasDecl(ReaderT, "readAll")) {
        const amount = try reader.readAll(buf);
        if (amount != buf.len) return QovError.UnexpectedEof;
        return;
    }
    const amount = try reader.readAtLeast(buf, buf.len);
    if (amount != buf.len) return QovError.UnexpectedEof;
}

fn readByteExact(reader: anytype) (QovError || readerErrorType(@TypeOf(reader)))!u8 {
    var buf: [1]u8 = undefined;
    try readExact(reader, &buf);
    return buf[0];
}

/// Reads and validates a QOV header from a stream.
pub fn readHeader(reader: anytype) (QovError || readerErrorType(@TypeOf(reader)))!Header {
    var buf: [header_size]u8 = undefined;
    try readExact(reader, &buf);

    if (!std.mem.eql(u8, buf[0..4], &magic)) return QovError.InvalidMagic;
    if (buf[4] != version) return QovError.UnsupportedVersion;

    const header = Header{
        .width = std.mem.readInt(u16, buf[5..7], .big),
        .height = std.mem.readInt(u16, buf[7..9], .big),
        .fps_num = std.mem.readInt(u16, buf[9..11], .big),
        .fps_den = std.mem.readInt(u16, buf[11..13], .big),
        .colorspace = try colorspaceFromByte(buf[13]),
        .channels = try channelsFromByte(buf[14]),
        .flags = @bitCast(buf[25]),
        .gop_size = buf[15],
        .has_audio = switch (buf[16]) {
            0 => false,
            1 => true,
            else => return QovError.InvalidHeader,
        },
        .audio_sample_rate = (@as(u32, buf[17]) << 16) | (@as(u32, buf[18]) << 8) | @as(u32, buf[19]),
        .audio_channels = buf[20],
        .audio_frames_per_chunk = std.mem.readInt(u16, buf[26..28], .big),
        .frame_count = std.mem.readInt(u32, buf[21..25], .big),
    };

    try validateHeader(header);

    return header;
}

/// Writes a validated QOV header to a stream.
pub fn writeHeader(writer: anytype, header: Header) (QovError || writerErrorType(@TypeOf(writer)))!void {
    try validateHeader(header);
    var buf: [header_size]u8 = undefined;
    @memset(&buf, 0);

    @memcpy(buf[0..4], &magic);
    buf[4] = version;
    std.mem.writeInt(u16, buf[5..7], header.width, .big);
    std.mem.writeInt(u16, buf[7..9], header.height, .big);
    std.mem.writeInt(u16, buf[9..11], header.fps_num, .big);
    std.mem.writeInt(u16, buf[11..13], header.fps_den, .big);
    buf[13] = colorspaceByte(header.colorspace);
    buf[14] = channelByte(header.channels);
    buf[15] = header.gop_size;
    buf[16] = if (header.has_audio) 1 else 0;
    buf[17] = @truncate(header.audio_sample_rate >> 16);
    buf[18] = @truncate(header.audio_sample_rate >> 8);
    buf[19] = @truncate(header.audio_sample_rate);
    buf[20] = header.audio_channels;
    std.mem.writeInt(u32, buf[21..25], header.frame_count, .big);
    buf[25] = @bitCast(header.flags);
    std.mem.writeInt(u16, buf[26..28], header.audio_frames_per_chunk, .big);

    try writer.writeAll(&buf);
}

/// Reads a chunk header, including duration metadata when enabled.
pub fn readChunkHeader(reader: anytype, has_metadata: bool) (QovError || readerErrorType(@TypeOf(reader)))!ChunkHeader {
    var buf: [chunk_header_metadata_size]u8 = undefined;
    const header_len = chunkHeaderSize(has_metadata);
    try readExact(reader, buf[0..header_len]);

    return ChunkHeader{
        .chunk_type = try chunkTypeFromByte(buf[0]),
        .payload_size = std.mem.readInt(u32, buf[1..5], .big),
        .frame_duration_us = if (has_metadata) std.mem.readInt(u32, buf[5..9], .big) else 0,
    };
}

/// Writes a chunk header, including duration metadata when enabled.
pub fn writeChunkHeader(writer: anytype, header: ChunkHeader, has_metadata: bool) (QovError || writerErrorType(@TypeOf(writer)))!void {
    var buf: [chunk_header_metadata_size]u8 = undefined;
    buf[0] = chunkTypeByte(header.chunk_type);
    std.mem.writeInt(u32, buf[1..5], header.payload_size, .big);
    if (has_metadata) {
        std.mem.writeInt(u32, buf[5..9], header.frame_duration_us, .big);
        try writer.writeAll(buf[0..chunk_header_metadata_size]);
    } else {
        try writer.writeAll(buf[0..chunk_header_size]);
    }
}

/// Reads an exact chunk payload into the provided buffer.
pub fn readChunkPayload(reader: anytype, payload: []u8) (QovError || readerErrorType(@TypeOf(reader)))!void {
    try readExact(reader, payload);
}

/// Writes a chunk payload to the stream.
pub fn writeChunkPayload(writer: anytype, payload: []const u8) (QovError || writerErrorType(@TypeOf(writer)))!void {
    try writer.writeAll(payload);
}

/// Validates an audio chunk payload containing concatenated QOA frames.
pub fn validateAudioChunkPayload(header: Header, payload: []const u8) QovError!void {
    if (!header.has_audio) return QovError.InvalidChunk;
    if (header.audio_channels == 0) return QovError.InvalidChunk;
    if (header.audio_channels > qoa_stream.max_channels) return QovError.InvalidChunk;

    const max_frame_bytes = qoa_stream.maxFrameBytes(header.audio_channels);
    const expected_frames: usize = @intCast(header.audio_frames_per_chunk);

    var offset: usize = 0;
    var frames_seen: usize = 0;
    while (offset < payload.len) {
        if (payload.len - offset < 8) return QovError.InvalidChunk;
        const frame_header = qoa_stream.parseFrameHeader(payload[offset..]) catch return QovError.InvalidChunk;
        if (frame_header.channels != header.audio_channels) return QovError.InvalidChunk;
        if (frame_header.sample_rate != header.audio_sample_rate) return QovError.InvalidChunk;
        if (frame_header.frame_length == 0) return QovError.InvalidChunk;

        const frame_size: usize = @intCast(frame_header.frame_size);
        if (frame_size < 8) return QovError.InvalidChunk;
        if (frame_size > max_frame_bytes) return QovError.InvalidChunk;
        if (offset + frame_size > payload.len) return QovError.InvalidChunk;

        offset += frame_size;
        frames_seen += 1;
        if (frames_seen > expected_frames) return QovError.InvalidChunk;
    }

    if (offset != payload.len) return QovError.InvalidChunk;
    if (frames_seen != expected_frames) return QovError.InvalidChunk;
}

/// Writes an audio chunk header and payload after validating QOA frames.
pub fn writeAudioChunk(writer: anytype, header: Header, payload: []const u8) (QovError || writerErrorType(@TypeOf(writer)))!void {
    try validateAudioChunkPayload(header, payload);
    if (payload.len > std.math.maxInt(u32)) return QovError.InvalidChunk;
    try writeChunkHeader(writer, .{
        .chunk_type = .audio,
        .payload_size = @intCast(payload.len),
        .frame_duration_us = 0,
    }, header.flags.frame_metadata);
    try writeChunkPayload(writer, payload);
}

/// Reads an audio chunk and validates the QOA payload.
pub fn readAudioChunk(reader: anytype, header: Header, payload: []u8) (QovError || readerErrorType(@TypeOf(reader)))!usize {
    if (!header.has_audio) return QovError.InvalidHeader;
    const chunk_header = try readChunkHeader(reader, header.flags.frame_metadata);
    if (chunk_header.chunk_type != .audio) return QovError.InvalidChunk;

    const payload_size: usize = @intCast(chunk_header.payload_size);
    if (payload_size > payload.len) return QovError.InvalidChunk;
    try readChunkPayload(reader, payload[0..payload_size]);
    try validateAudioChunkPayload(header, payload[0..payload_size]);
    return payload_size;
}

fn maxFramePayloadBytes(header: Header) usize {
    const pixel_count = headerFramePixels(header);
    return pixel_count * 5 + end_marker.len;
}

const EncodeJobContext = struct {
    frames: []const []const u8,
    rgba_frames: ?[][]u8,
    use_iframes: []const bool,
    payload_buffers: [][]u8,
    payload_sizes: []usize,
    has_error: *std.atomic.Value(bool),
    err_mutex: *std.Thread.Mutex,
    stored_err: *?QovError,
    rgb_only: bool,
};

fn recordEncodeError(ctx: *EncodeJobContext, err: QovError) void {
    ctx.has_error.store(true, .seq_cst);
    ctx.err_mutex.lock();
    defer ctx.err_mutex.unlock();
    if (ctx.stored_err.* == null) {
        ctx.stored_err.* = err;
    }
}

fn encodeFrameJob(ctx: *EncodeJobContext, index: usize) void {
    if (ctx.has_error.load(.seq_cst)) return;

    const use_iframe = ctx.use_iframes[index];
    var stream_writer: std.Io.Writer = .fixed(ctx.payload_buffers[index]);

    if (ctx.rgb_only) {
        const rgba_frames = ctx.rgba_frames orelse {
            recordEncodeError(ctx, QovError.InvalidChunk);
            return;
        };
        const curr = rgba_frames[index];
        if (use_iframe) {
            encodeIFrame(&stream_writer, curr) catch |err| {
                if (err == error.NoSpaceLeft) {
                    recordEncodeError(ctx, QovError.InvalidChunk);
                } else {
                    recordEncodeError(ctx, @errorCast(err));
                }
                return;
            };
        } else {
            const prev = rgba_frames[index - 1];
            encodePFrame(&stream_writer, curr, prev) catch |err| {
                if (err == error.NoSpaceLeft) {
                    recordEncodeError(ctx, QovError.InvalidChunk);
                } else {
                    recordEncodeError(ctx, @errorCast(err));
                }
                return;
            };
        }
    } else {
        const curr = ctx.frames[index];
        if (use_iframe) {
            encodeIFrame(&stream_writer, curr) catch |err| {
                if (err == error.NoSpaceLeft) {
                    recordEncodeError(ctx, QovError.InvalidChunk);
                } else {
                    recordEncodeError(ctx, @errorCast(err));
                }
                return;
            };
        } else {
            const prev = ctx.frames[index - 1];
            encodePFrame(&stream_writer, curr, prev) catch |err| {
                if (err == error.NoSpaceLeft) {
                    recordEncodeError(ctx, QovError.InvalidChunk);
                } else {
                    recordEncodeError(ctx, @errorCast(err));
                }
                return;
            };
        }
    }

    ctx.payload_sizes[index] = stream_writer.end;
}

const AudioChunkState = struct {
    chunks: []const []const u8,
    index: usize = 0,
};

fn writeNextAudioChunk(writer: anytype, header: Header, audio_state: ?*AudioChunkState) (QovError || writerErrorType(@TypeOf(writer)))!void {
    if (audio_state) |state| {
        if (state.index < state.chunks.len) {
            try writeAudioChunk(writer, header, state.chunks[state.index]);
            state.index += 1;
        }
    }
}

fn writeRemainingAudioChunks(writer: anytype, header: Header, audio_state: ?*AudioChunkState) (QovError || writerErrorType(@TypeOf(writer)))!void {
    if (audio_state) |state| {
        while (state.index < state.chunks.len) : (state.index += 1) {
            try writeAudioChunk(writer, header, state.chunks[state.index]);
        }
    }
}

fn encodeStreamSequential(allocator: std.mem.Allocator, writer: anytype, header: Header, frames: []const []const u8, frame_durations_us: ?[]const u32, default_frame_duration_us: u32, audio_state: ?*AudioChunkState) (QovError || std.mem.Allocator.Error || writerErrorType(@TypeOf(writer)))!void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);

    var prev_pixels: ?[]const u8 = null;
    const rgb_only = header.flags.rgb_only;
    var rgba_curr: ?[]u8 = null;
    var rgba_prev: ?[]u8 = null;
    var rgba_a: ?[]u8 = null;
    var rgba_b: ?[]u8 = null;
    errdefer if (rgba_a) |buffer| allocator.free(buffer);
    errdefer if (rgba_b) |buffer| allocator.free(buffer);
    if (rgb_only) {
        const rgba_bytes = headerFramePixels(header) * 4;
        rgba_a = try allocator.alloc(u8, rgba_bytes);
        rgba_b = try allocator.alloc(u8, rgba_bytes);
        rgba_curr = rgba_a;
        rgba_prev = rgba_b;
    }
    defer {
        if (rgba_a) |buffer| allocator.free(buffer);
        if (rgba_b) |buffer| allocator.free(buffer);
    }

    const has_frame_metadata = header.flags.frame_metadata;

    for (frames, 0..) |frame, index| {
        payload.clearRetainingCapacity();
        var payload_writer_alloc: std.Io.Writer.Allocating = .fromArrayList(allocator, &payload);

        const use_iframe = index == 0 or header.gop_size == 0 or (index % header.gop_size == 0);
        const frame_duration_us: u32 = if (has_frame_metadata) blk: {
            if (frame_durations_us) |durations| {
                break :blk durations[index];
            }
            break :blk default_frame_duration_us;
        } else 0;

        if (rgb_only) {
            const curr = rgba_curr orelse return QovError.InvalidChunk;
            const prev = rgba_prev orelse return QovError.InvalidChunk;
            expandRgbToRgba(curr, frame);
            if (use_iframe) {
                try encodeIFrame(&payload_writer_alloc.writer, curr);
            } else {
                try encodePFrame(&payload_writer_alloc.writer, curr, prev);
            }
            rgba_curr = prev;
            rgba_prev = curr;
            prev_pixels = rgba_prev;
        } else {
            if (use_iframe) {
                try encodeIFrame(&payload_writer_alloc.writer, frame);
            } else {
                const prev = prev_pixels orelse return QovError.InvalidChunk;
                try encodePFrame(&payload_writer_alloc.writer, frame, prev);
            }
            prev_pixels = frame;
        }
        payload = payload_writer_alloc.toArrayList();

        if (payload.items.len > std.math.maxInt(u32)) return QovError.InvalidChunk;

        try writeChunkHeader(writer, .{
            .chunk_type = if (use_iframe) .iframe else .pframe,
            .payload_size = @intCast(payload.items.len),
            .frame_duration_us = frame_duration_us,
        }, has_frame_metadata);
        try writeChunkPayload(writer, payload.items);
        try writeNextAudioChunk(writer, header, audio_state);
    }

    try writeRemainingAudioChunks(writer, header, audio_state);
}

/// Encodes a full stream with default options.
pub fn encodeStream(allocator: std.mem.Allocator, writer: anytype, header: Header, frames: []const []const u8, frame_durations_us: ?[]const u32) (QovError || std.mem.Allocator.Error || writerErrorType(@TypeOf(writer)))!void {
    return encodeStreamWithOptions(allocator, writer, header, frames, frame_durations_us, .{});
}

/// Encodes a stream with configurable options, including parallel preprocessing.
pub fn encodeStreamWithOptions(allocator: std.mem.Allocator, writer: anytype, header: Header, frames: []const []const u8, frame_durations_us: ?[]const u32, options: EncodeOptions) (QovError || std.mem.Allocator.Error || writerErrorType(@TypeOf(writer)))!void {
    try validateHeader(header);

    if (options.audio_chunks) |audio_chunks| {
        if (!header.has_audio) return QovError.InvalidHeader;
        for (audio_chunks) |payload| {
            if (payload.len > std.math.maxInt(u32)) return QovError.InvalidChunk;
            try validateAudioChunkPayload(header, payload);
        }
    }

    if (header.frame_count != 0 and header.frame_count != frames.len) return QovError.InvalidHeader;
    if (header.flags.frame_metadata) {
        if (frame_durations_us) |durations| {
            if (durations.len != frames.len) return QovError.InvalidHeader;
        }
    } else if (frame_durations_us != null) {
        return QovError.InvalidHeader;
    }

    const expected_bytes = headerFrameBytes(header);
    for (frames) |frame| {
        if (frame.len != expected_bytes) return QovError.FrameSizeMismatch;
    }

    try writeHeader(writer, header);

    const has_frame_metadata = header.flags.frame_metadata;
    const default_frame_duration_us: u32 = if (has_frame_metadata and frame_durations_us == null) blk: {
        const duration = @as(u64, header.fps_den) * 1_000_000 / @as(u64, header.fps_num);
        if (duration == 0 or duration > std.math.maxInt(u32)) return QovError.InvalidHeader;
        break :blk @intCast(duration);
    } else 0;

    var audio_state_storage: ?AudioChunkState = if (options.audio_chunks) |audio_chunks| .{ .chunks = audio_chunks } else null;
    const audio_state: ?*AudioChunkState = if (audio_state_storage) |*state| state else null;

    _ = options.parallel;
    _ = options.max_threads;
    try encodeStreamSequential(allocator, writer, header, frames, frame_durations_us, default_frame_duration_us, audio_state);
}

/// Streaming decoder that reads headers once and advances frame-by-frame.
pub fn StreamDecoder(comptime ReaderType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        reader: ReaderType,
        header: Header,
        payload: std.ArrayList(u8),
        rgba_curr: ?[]u8 = null,
        rgba_prev: ?[]u8 = null,
        frame_index: usize = 0,
        last_frame_duration_us: u32 = 0,

        pub const StreamPacket = union(enum) {
            frame: void,
            audio: []const u8,
        };

        pub fn init(allocator: std.mem.Allocator, reader: ReaderType) (QovError || std.mem.Allocator.Error || readerErrorType(ReaderType))!@This() {
            const header = try readHeader(reader);
            var decoder = @This(){
                .allocator = allocator,
                .reader = reader,
                .header = header,
                .payload = std.ArrayList(u8).empty,
                .rgba_curr = null,
                .rgba_prev = null,
                .frame_index = 0,
            };
            // Always allocate double buffers for P-frame decoding
            // (rgb_only needs them for expand/strip, non-rgb_only needs them to
            // avoid reading from the same buffer we're writing to)
            const rgba_bytes = headerFramePixels(header) * 4;
            const buffer_a = try allocator.alloc(u8, rgba_bytes);
            errdefer allocator.free(buffer_a);
            const buffer_b = try allocator.alloc(u8, rgba_bytes);
            errdefer allocator.free(buffer_b);
            decoder.rgba_curr = buffer_a;
            decoder.rgba_prev = buffer_b;
            return decoder;
        }

        pub fn deinit(self: *@This()) void {
            self.payload.deinit(self.allocator);
            if (self.rgba_curr) |buffer| self.allocator.free(buffer);
            if (self.rgba_prev) |buffer| self.allocator.free(buffer);
        }

        pub fn nextFrame(self: *@This(), frame: []u8) (QovError || std.mem.Allocator.Error || readerErrorType(ReaderType))!bool {
            const expected_bytes = headerFrameBytes(self.header);
            if (frame.len != expected_bytes) return QovError.FrameSizeMismatch;
            while (true) {
                const packet = try self.nextPacket(frame);
                if (packet == null) return false;
                switch (packet.?) {
                    .frame => return true,
                    .audio => continue,
                }
            }
        }

        pub fn nextPacket(self: *@This(), frame: ?[]u8) (QovError || std.mem.Allocator.Error || readerErrorType(ReaderType))!?StreamPacket {
            const chunk_header = readChunkHeader(self.reader, self.header.flags.frame_metadata) catch |err| switch (err) {
                QovError.UnexpectedEof => {
                    if (self.header.frame_count == 0) return null;
                    if (self.frame_index >= self.header.frame_count) return null;
                    return err;
                },
                else => return err,
            };
            const payload_size: usize = @intCast(chunk_header.payload_size);

            try self.payload.resize(self.allocator, payload_size);
            try readChunkPayload(self.reader, self.payload.items);

            switch (chunk_header.chunk_type) {
                .audio => {
                    if (!self.header.has_audio) return QovError.InvalidChunk;
                    try validateAudioChunkPayload(self.header, self.payload.items);
                    return StreamPacket{ .audio = self.payload.items };
                },
                .iframe, .pframe => {
                    const expected_bytes = headerFrameBytes(self.header);
                    const frame_buf = frame orelse return QovError.FrameSizeMismatch;
                    if (frame_buf.len != expected_bytes) return QovError.FrameSizeMismatch;
                    if (self.header.frame_count != 0 and self.frame_index >= self.header.frame_count) return QovError.InvalidChunk;

                    self.last_frame_duration_us = chunk_header.frame_duration_us;

                    var stream_reader: std.Io.Reader = .fixed(self.payload.items);

                    switch (chunk_header.chunk_type) {
                        .iframe => {
                            const curr = self.rgba_curr orelse return QovError.InvalidChunk;
                            const prev = self.rgba_prev orelse return QovError.InvalidChunk;
                            try decodeIFrame(&stream_reader, curr);
                            if (self.header.flags.rgb_only) {
                                stripRgbaToRgb(frame_buf, curr);
                            } else {
                                @memcpy(frame_buf, curr);
                            }
                            self.rgba_curr = prev;
                            self.rgba_prev = curr;
                        },
                        .pframe => {
                            const curr = self.rgba_curr orelse return QovError.InvalidChunk;
                            const prev = self.rgba_prev orelse return QovError.InvalidChunk;
                            try decodePFrame(&stream_reader, curr, prev);
                            if (self.header.flags.rgb_only) {
                                stripRgbaToRgb(frame_buf, curr);
                            } else {
                                @memcpy(frame_buf, curr);
                            }
                            self.rgba_curr = prev;
                            self.rgba_prev = curr;
                        },
                        else => return QovError.InvalidChunk,
                    }

                    if (stream_reader.seek != self.payload.items.len) return QovError.InvalidChunk;

                    self.frame_index += 1;
                    return StreamPacket{ .frame = {} };
                },
            }
        }
    };
}

/// Decodes a full stream into preallocated frame buffers.
pub fn decodeStream(allocator: std.mem.Allocator, reader: anytype, frames: [][]u8) (QovError || std.mem.Allocator.Error || readerErrorType(@TypeOf(reader)))!Header {
    var decoder = try StreamDecoder(@TypeOf(reader)).init(allocator, reader);
    defer decoder.deinit();

    if (decoder.header.frame_count != 0 and decoder.header.frame_count != frames.len) return QovError.InvalidHeader;

    for (frames) |frame| {
        const had_frame = try decoder.nextFrame(frame);
        if (!had_frame) {
            if (decoder.header.frame_count == 0) return decoder.header;
            return QovError.UnexpectedEof;
        }
    }

    return decoder.header;
}

const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn hash(self: Rgba) u6 {
        return @truncate(self.r *% 3 +% self.g *% 5 +% self.b *% 7 +% self.a *% 11);
    }

    fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

fn rgbaFromSlice(pixels: []const u8, index: usize) Rgba {
    const base = index * 4;
    return Rgba{
        .r = pixels[base],
        .g = pixels[base + 1],
        .b = pixels[base + 2],
        .a = pixels[base + 3],
    };
}

fn writeRgba(pixels: []u8, index: usize, color: Rgba) void {
    const base = index * 4;
    pixels[base] = color.r;
    pixels[base + 1] = color.g;
    pixels[base + 2] = color.b;
    pixels[base + 3] = color.a;
}

fn expandRgbToRgba(dst: []u8, src: []const u8) void {
    std.debug.assert(src.len % 3 == 0);
    std.debug.assert(dst.len == (src.len / 3) * 4);
    var src_index: usize = 0;
    var dst_index: usize = 0;
    while (src_index < src.len) : (src_index += 3) {
        dst[dst_index] = src[src_index];
        dst[dst_index + 1] = src[src_index + 1];
        dst[dst_index + 2] = src[src_index + 2];
        dst[dst_index + 3] = 0xFF;
        dst_index += 4;
    }
}

fn stripRgbaToRgb(dst: []u8, src: []const u8) void {
    std.debug.assert(src.len % 4 == 0);
    std.debug.assert(dst.len == (src.len / 4) * 3);
    var src_index: usize = 0;
    var dst_index: usize = 0;
    while (src_index < src.len) : (src_index += 4) {
        dst[dst_index] = src[src_index];
        dst[dst_index + 1] = src[src_index + 1];
        dst[dst_index + 2] = src[src_index + 2];
        dst_index += 3;
    }
}

/// Encodes a standalone iframe payload for RGBA pixels.
pub fn encodeIFrame(writer: anytype, pixels: []const u8) (QovError || writerErrorType(@TypeOf(writer)))!void {
    if (pixels.len % 4 != 0) return QovError.InvalidChunk;

    var color_lut = std.mem.zeroes([64]Rgba);
    var prev_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var run_length: usize = 0;

    const pixel_count = pixels.len / 4;
    for (0..pixel_count) |i| {
        const pixel = rgbaFromSlice(pixels, i);
        const same_pixel = pixel.eql(prev_pixel);

        if (same_pixel) {
            run_length += 1;
        }

        if (run_length > 0 and (run_length == 62 or !same_pixel or i == pixel_count - 1)) {
            try writer.writeByte(0b1100_0000 | @as(u8, @truncate(run_length - 1)));
            run_length = 0;
        }

        if (!same_pixel) {
            const hash = pixel.hash();
            if (color_lut[hash].eql(pixel)) {
                try writer.writeByte(0b0000_0000 | hash);
            } else {
                color_lut[hash] = pixel;

                const diff_r = @as(i16, pixel.r) - @as(i16, prev_pixel.r);
                const diff_g = @as(i16, pixel.g) - @as(i16, prev_pixel.g);
                const diff_b = @as(i16, pixel.b) - @as(i16, prev_pixel.b);
                const diff_a = @as(i16, pixel.a) - @as(i16, prev_pixel.a);

                const diff_rg = diff_r - diff_g;
                const diff_rb = diff_b - diff_g;

                if (diff_a == 0 and inRange2(diff_r) and inRange2(diff_g) and inRange2(diff_b)) {
                    const byte = 0b0100_0000 |
                        (mapRange2(diff_r) << 4) |
                        (mapRange2(diff_g) << 2) |
                        (mapRange2(diff_b) << 0);
                    try writer.writeByte(byte);
                } else if (diff_a == 0 and inRange6(diff_g) and inRange4(diff_rg) and inRange4(diff_rb)) {
                    try writer.writeAll(&[2]u8{
                        0b1000_0000 | mapRange6(diff_g),
                        (mapRange4(diff_rg) << 4) | (mapRange4(diff_rb) << 0),
                    });
                } else if (diff_a == 0) {
                    try writer.writeAll(&[4]u8{
                        0b1111_1110,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                    });
                } else {
                    try writer.writeAll(&[5]u8{
                        0b1111_1111,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                        pixel.a,
                    });
                }
            }
        }

        prev_pixel = pixel;
    }

    try writer.writeAll(&end_marker);
}

/// Decodes a standalone iframe payload into RGBA pixels.
pub fn decodeIFrame(reader: anytype, pixels: []u8) (QovError || readerErrorType(@TypeOf(reader)))!void {
    if (pixels.len % 4 != 0) return QovError.InvalidChunk;

    var color_lut = std.mem.zeroes([64]Rgba);
    var prev_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0xFF };

    const pixel_count = pixels.len / 4;
    var index: usize = 0;

    while (index < pixel_count) {
        const byte = try readByteExact(reader);

        var new_pixel = prev_pixel;
        var count: usize = 1;

        if (byte == 0b1111_1110) {
            new_pixel.r = try readByteExact(reader);
            new_pixel.g = try readByteExact(reader);
            new_pixel.b = try readByteExact(reader);
        } else if (byte == 0b1111_1111) {
            new_pixel.r = try readByteExact(reader);
            new_pixel.g = try readByteExact(reader);
            new_pixel.b = try readByteExact(reader);
            new_pixel.a = try readByteExact(reader);
        } else if (hasPrefix(byte, u2, 0b00)) {
            const color_index: u6 = @truncate(byte);
            new_pixel = color_lut[color_index];
        } else if (hasPrefix(byte, u2, 0b01)) {
            const diff_r = unmapRange2(byte >> 4);
            const diff_g = unmapRange2(byte >> 2);
            const diff_b = unmapRange2(byte >> 0);

            add8(&new_pixel.r, diff_r);
            add8(&new_pixel.g, diff_g);
            add8(&new_pixel.b, diff_b);
        } else if (hasPrefix(byte, u2, 0b10)) {
            const diff_g = unmapRange6(byte);
            const diff_rg_rb = try readByteExact(reader);

            const diff_rg = unmapRange4(diff_rg_rb >> 4);
            const diff_rb = unmapRange4(diff_rg_rb >> 0);

            const diff_r = @as(i8, diff_g) + diff_rg;
            const diff_b = @as(i8, diff_g) + diff_rb;

            add8(&new_pixel.r, diff_r);
            add8(&new_pixel.g, diff_g);
            add8(&new_pixel.b, diff_b);
        } else if (hasPrefix(byte, u2, 0b11)) {
            count = @as(usize, @as(u6, @truncate(byte))) + 1;
            if (count > 62) return QovError.InvalidChunk;
        } else {
            return QovError.InvalidChunk;
        }

        if (index + count > pixel_count) return QovError.InvalidChunk;

        while (count > 0) {
            count -= 1;
            writeRgba(pixels, index, new_pixel);
            index += 1;
        }

        color_lut[new_pixel.hash()] = new_pixel;
        prev_pixel = new_pixel;
    }

    var marker: [end_marker.len]u8 = undefined;
    try readExact(reader, &marker);
    if (!std.mem.eql(u8, &marker, &end_marker)) return QovError.InvalidChunk;
}

/// Encodes a delta pframe payload using a previous RGBA frame.
pub fn encodePFrame(writer: anytype, pixels: []const u8, prev_pixels: []const u8) (QovError || writerErrorType(@TypeOf(writer)))!void {
    if (pixels.len % 4 != 0) return QovError.InvalidChunk;
    if (pixels.len != prev_pixels.len) return QovError.InvalidChunk;

    var color_lut = std.mem.zeroes([64]Rgba);
    var prev_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var trun_length: usize = 0;

    const pixel_count = pixels.len / 4;
    for (0..pixel_count) |i| {
        const pixel = rgbaFromSlice(pixels, i);
        const temporal = rgbaFromSlice(prev_pixels, i);
        const same_temporal = pixel.eql(temporal);

        if (!same_temporal and trun_length > 0) {
            try writer.writeAll(&[2]u8{ 0xFC, @as(u8, @truncate(trun_length - 1)) });
            trun_length = 0;
        }

        if (same_temporal) {
            trun_length += 1;
            color_lut[pixel.hash()] = pixel;
            prev_pixel = pixel;

            if (trun_length == 256) {
                try writer.writeAll(&[2]u8{ 0xFC, 0xFF });
                trun_length = 0;
            }
            continue;
        }

        if (encodeTdiff(pixel, temporal)) |tdiff_byte| {
            try writer.writeAll(&[2]u8{ 0xFD, tdiff_byte });
            color_lut[pixel.hash()] = pixel;
        } else {
            const hash = pixel.hash();
            if (color_lut[hash].eql(pixel)) {
                try writer.writeByte(0b0000_0000 | hash);
            } else {
                color_lut[hash] = pixel;

                const diff_r = @as(i16, pixel.r) - @as(i16, prev_pixel.r);
                const diff_g = @as(i16, pixel.g) - @as(i16, prev_pixel.g);
                const diff_b = @as(i16, pixel.b) - @as(i16, prev_pixel.b);
                const diff_a = @as(i16, pixel.a) - @as(i16, prev_pixel.a);

                const diff_rg = diff_r - diff_g;
                const diff_rb = diff_b - diff_g;

                if (diff_a == 0 and inRange2(diff_r) and inRange2(diff_g) and inRange2(diff_b)) {
                    const byte = 0b0100_0000 |
                        (mapRange2(diff_r) << 4) |
                        (mapRange2(diff_g) << 2) |
                        (mapRange2(diff_b) << 0);
                    try writer.writeByte(byte);
                } else if (diff_a == 0 and inRange6(diff_g) and inRange4(diff_rg) and inRange4(diff_rb)) {
                    try writer.writeAll(&[2]u8{
                        0b1000_0000 | mapRange6(diff_g),
                        (mapRange4(diff_rg) << 4) | (mapRange4(diff_rb) << 0),
                    });
                } else if (diff_a == 0) {
                    try writer.writeAll(&[4]u8{
                        0b1111_1110,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                    });
                } else {
                    try writer.writeAll(&[5]u8{
                        0b1111_1111,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                        pixel.a,
                    });
                }
            }
        }

        prev_pixel = pixel;
    }

    if (trun_length > 0) {
        try writer.writeAll(&[2]u8{ 0xFC, @as(u8, @truncate(trun_length - 1)) });
    }

    try writer.writeAll(&end_marker);
}

/// Decodes a delta pframe payload using a previous RGBA frame.
pub fn decodePFrame(reader: anytype, pixels: []u8, prev_pixels: []const u8) (QovError || readerErrorType(@TypeOf(reader)))!void {
    if (pixels.len % 4 != 0) return QovError.InvalidChunk;
    if (pixels.len != prev_pixels.len) return QovError.InvalidChunk;

    var color_lut = std.mem.zeroes([64]Rgba);
    var prev_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0xFF };

    const pixel_count = pixels.len / 4;
    var index: usize = 0;

    while (index < pixel_count) {
        const byte = try readByteExact(reader);

        if (byte == 0xFC) {
            const count = @as(usize, try readByteExact(reader)) + 1;
            if (index + count > pixel_count) return QovError.InvalidChunk;

            var remaining = count;
            while (remaining > 0) {
                remaining -= 1;
                const temporal = rgbaFromSlice(prev_pixels, index);
                writeRgba(pixels, index, temporal);
                color_lut[temporal.hash()] = temporal;
                prev_pixel = temporal;
                index += 1;
            }
            continue;
        }

        if (byte == 0xFD) {
            const diff_byte = try readByteExact(reader);
            if ((diff_byte & 0x1) != 0) return QovError.InvalidChunk;

            var new_pixel = rgbaFromSlice(prev_pixels, index);
            const sign = diff_byte >> 7;
            const diff_r = if (sign == 0) @as(i8, @intCast((diff_byte >> 5) & 0x3)) else -@as(i8, @intCast((diff_byte >> 5) & 0x3));
            const diff_g = if (sign == 0) @as(i8, @intCast((diff_byte >> 3) & 0x3)) else -@as(i8, @intCast((diff_byte >> 3) & 0x3));
            const diff_b = if (sign == 0) @as(i8, @intCast((diff_byte >> 1) & 0x3)) else -@as(i8, @intCast((diff_byte >> 1) & 0x3));

            add8(&new_pixel.r, diff_r);
            add8(&new_pixel.g, diff_g);
            add8(&new_pixel.b, diff_b);

            writeRgba(pixels, index, new_pixel);
            index += 1;
            color_lut[new_pixel.hash()] = new_pixel;
            prev_pixel = new_pixel;
            continue;
        }

        var new_pixel = prev_pixel;
        var count: usize = 1;

        if (byte == 0b1111_1110) {
            new_pixel.r = try readByteExact(reader);
            new_pixel.g = try readByteExact(reader);
            new_pixel.b = try readByteExact(reader);
        } else if (byte == 0b1111_1111) {
            new_pixel.r = try readByteExact(reader);
            new_pixel.g = try readByteExact(reader);
            new_pixel.b = try readByteExact(reader);
            new_pixel.a = try readByteExact(reader);
        } else if (hasPrefix(byte, u2, 0b00)) {
            const color_index: u6 = @truncate(byte);
            new_pixel = color_lut[color_index];
        } else if (hasPrefix(byte, u2, 0b01)) {
            const diff_r = unmapRange2(byte >> 4);
            const diff_g = unmapRange2(byte >> 2);
            const diff_b = unmapRange2(byte >> 0);

            add8(&new_pixel.r, diff_r);
            add8(&new_pixel.g, diff_g);
            add8(&new_pixel.b, diff_b);
        } else if (hasPrefix(byte, u2, 0b10)) {
            const diff_g = unmapRange6(byte);
            const diff_rg_rb = try readByteExact(reader);

            const diff_rg = unmapRange4(diff_rg_rb >> 4);
            const diff_rb = unmapRange4(diff_rg_rb >> 0);

            const diff_r = @as(i8, diff_g) + diff_rg;
            const diff_b = @as(i8, diff_g) + diff_rb;

            add8(&new_pixel.r, diff_r);
            add8(&new_pixel.g, diff_g);
            add8(&new_pixel.b, diff_b);
        } else if (hasPrefix(byte, u2, 0b11)) {
            count = @as(usize, @as(u6, @truncate(byte))) + 1;
            if (count > 62) return QovError.InvalidChunk;
        } else {
            return QovError.InvalidChunk;
        }

        if (index + count > pixel_count) return QovError.InvalidChunk;

        while (count > 0) {
            count -= 1;
            writeRgba(pixels, index, new_pixel);
            index += 1;
        }

        color_lut[new_pixel.hash()] = new_pixel;
        prev_pixel = new_pixel;
    }

    var marker: [end_marker.len]u8 = undefined;
    try readExact(reader, &marker);
    if (!std.mem.eql(u8, &marker, &end_marker)) return QovError.InvalidChunk;
}

fn encodeTdiff(pixel: Rgba, temporal: Rgba) ?u8 {
    if (pixel.a != temporal.a) return null;

    const diff_r = @as(i16, pixel.r) - @as(i16, temporal.r);
    const diff_g = @as(i16, pixel.g) - @as(i16, temporal.g);
    const diff_b = @as(i16, pixel.b) - @as(i16, temporal.b);

    if (diff_r >= 0 and diff_g >= 0 and diff_b >= 0 and diff_r <= 3 and diff_g <= 3 and diff_b <= 3) {
        return (@as(u8, 0) << 7) |
            (@as(u8, @intCast(diff_r)) << 5) |
            (@as(u8, @intCast(diff_g)) << 3) |
            (@as(u8, @intCast(diff_b)) << 1);
    }

    if (diff_r <= 0 and diff_g <= 0 and diff_b <= 0 and diff_r >= -3 and diff_g >= -3 and diff_b >= -3) {
        return (@as(u8, 1) << 7) |
            (@as(u8, @intCast(-diff_r)) << 5) |
            (@as(u8, @intCast(-diff_g)) << 3) |
            (@as(u8, @intCast(-diff_b)) << 1);
    }

    return null;
}

fn mapRange2(val: i16) u8 {
    return @as(u2, @intCast(val + 2));
}

fn mapRange4(val: i16) u8 {
    return @as(u4, @intCast(val + 8));
}

fn mapRange6(val: i16) u8 {
    return @as(u6, @intCast(val + 32));
}

fn unmapRange2(val: u32) i2 {
    return @as(i2, @intCast(@as(i8, @as(u2, @truncate(val))) - 2));
}

fn unmapRange4(val: u32) i4 {
    return @as(i4, @intCast(@as(i8, @as(u4, @truncate(val))) - 8));
}

fn unmapRange6(val: u32) i6 {
    return @as(i6, @intCast(@as(i8, @as(u6, @truncate(val))) - 32));
}

fn inRange2(val: i16) bool {
    return (val >= -2) and (val <= 1);
}

fn inRange4(val: i16) bool {
    return (val >= -8) and (val <= 7);
}

fn inRange6(val: i16) bool {
    return (val >= -32) and (val <= 31);
}

fn add8(dst: *u8, diff: i8) void {
    dst.* +%= @bitCast(diff);
}

fn hasPrefix(value: u8, comptime T: type, prefix: T) bool {
    return (@as(T, @truncate(value >> (8 - @bitSizeOf(T)))) == prefix);
}

fn testArrayListWriter(list: *std.ArrayList(u8)) std.Io.Writer.Allocating {
    return .fromArrayList(std.testing.allocator, list);
}

fn finishTestArrayListWriter(list: *std.ArrayList(u8), writer: *std.Io.Writer.Allocating) void {
    list.* = writer.toArrayList();
}

test "header validation for RGBA-only frames" {
    const header = Header{
        .width = 2,
        .height = 3,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 30,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 0,
    };

    try validateHeader(header);
    try std.testing.expectEqual(@as(usize, 24), headerFrameBytes(header));
}

test "header validation for RGB-only frames" {
    const header = Header{
        .width = 2,
        .height = 3,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgb,
        .flags = .{ .rgb_only = true },
        .gop_size = 30,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 0,
    };

    try validateHeader(header);
    try std.testing.expectEqual(@as(usize, 18), headerFrameBytes(header));
}

test "header read/write roundtrip" {
    const header = Header{
        .width = 320,
        .height = 240,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 10,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 12,
    };

    var buffer: [header_size]u8 = undefined;
    var stream_writer: std.Io.Writer = .fixed(&buffer);
    try writeHeader(&stream_writer, header);

    var stream_reader: std.Io.Reader = .fixed(stream_writer.buffered());
    const decoded = try readHeader(&stream_reader);

    try std.testing.expectEqual(header.width, decoded.width);
    try std.testing.expectEqual(header.height, decoded.height);
    try std.testing.expectEqual(header.fps_num, decoded.fps_num);
    try std.testing.expectEqual(header.fps_den, decoded.fps_den);
    try std.testing.expectEqual(header.colorspace, decoded.colorspace);
    try std.testing.expectEqual(header.channels, decoded.channels);
    try std.testing.expectEqual(header.gop_size, decoded.gop_size);
    try std.testing.expectEqual(header.has_audio, decoded.has_audio);
    try std.testing.expectEqual(header.audio_sample_rate, decoded.audio_sample_rate);
    try std.testing.expectEqual(header.audio_channels, decoded.audio_channels);
    try std.testing.expectEqual(header.audio_frames_per_chunk, decoded.audio_frames_per_chunk);
    try std.testing.expectEqual(header.frame_count, decoded.frame_count);
    try std.testing.expectEqual(header.flags, decoded.flags);
}

test "chunk header and payload read/write roundtrip" {
    const payload = "qov";
    const header = ChunkHeader{
        .chunk_type = .iframe,
        .payload_size = payload.len,
    };

    const header_len: usize = chunk_header_size;
    var buffer: [header_len + payload.len]u8 = undefined;
    var stream_writer: std.Io.Writer = .fixed(&buffer);
    try writeChunkHeader(&stream_writer, header, false);
    try writeChunkPayload(&stream_writer, payload);

    var stream_reader: std.Io.Reader = .fixed(stream_writer.buffered());
    const decoded_header = try readChunkHeader(&stream_reader, false);

    var decoded_payload: [payload.len]u8 = undefined;
    try readChunkPayload(&stream_reader, &decoded_payload);

    try std.testing.expectEqual(header.chunk_type, decoded_header.chunk_type);
    try std.testing.expectEqual(header.payload_size, decoded_header.payload_size);
    try std.testing.expect(std.mem.eql(u8, payload, &decoded_payload));
}

test "chunk header and payload read/write roundtrip with metadata" {
    const payload = "qov";
    const header = ChunkHeader{
        .chunk_type = .pframe,
        .payload_size = payload.len,
        .frame_duration_us = 41_666,
    };

    const header_len: usize = chunk_header_metadata_size;
    var buffer: [header_len + payload.len]u8 = undefined;
    var stream_writer: std.Io.Writer = .fixed(&buffer);
    try writeChunkHeader(&stream_writer, header, true);
    try writeChunkPayload(&stream_writer, payload);

    var stream_reader: std.Io.Reader = .fixed(stream_writer.buffered());
    const decoded_header = try readChunkHeader(&stream_reader, true);

    var decoded_payload: [payload.len]u8 = undefined;
    try readChunkPayload(&stream_reader, &decoded_payload);

    try std.testing.expectEqual(header.chunk_type, decoded_header.chunk_type);
    try std.testing.expectEqual(header.payload_size, decoded_header.payload_size);
    try std.testing.expectEqual(header.frame_duration_us, decoded_header.frame_duration_us);
    try std.testing.expect(std.mem.eql(u8, payload, &decoded_payload));
}

test "I-frame encode/decode roundtrip" {
    const pixels = [_]u8{
        0, 0, 0, 255,
        0, 0, 0, 255,
        10, 20, 30, 255,
        10, 20, 30, 255,
        11, 21, 31, 254,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeIFrame(&encoded_writer_alloc.writer, &pixels);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var decoded: [pixels.len]u8 = undefined;
    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    try decodeIFrame(&stream_reader, &decoded);

    try std.testing.expectEqualSlices(u8, &pixels, &decoded);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "P-frame encode/decode roundtrip with temporal ops" {
    const prev_pixels = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        5, 5, 5, 255,
        8, 9, 10, 255,
    };

    const pixels = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        7, 7, 7, 255,
        30, 40, 50, 254,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodePFrame(&encoded_writer_alloc.writer, &pixels, &prev_pixels);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var decoded: [pixels.len]u8 = undefined;
    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    try decodePFrame(&stream_reader, &decoded, &prev_pixels);

    try std.testing.expectEqualSlices(u8, &pixels, &decoded);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.items, 0xFC) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.items, 0xFD) != null);
}

test "stream encode/decode roundtrip" {
    const header = Header{
        .width = 2,
        .height = 2,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 2,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    const frame0 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
    };

    const frame1 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        41, 51, 61, 255,
        70, 80, 90, 255,
    };

    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStream(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;
    var out_frames = [_][]u8{ &out0, &out1 };

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    const decoded_header = try decodeStream(std.testing.allocator, &stream_reader, &out_frames);

    try std.testing.expectEqual(header.width, decoded_header.width);
    try std.testing.expectEqual(header.height, decoded_header.height);
    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);
    try std.testing.expectEqualSlices(u8, &frame0, out_frames[0]);
    try std.testing.expectEqualSlices(u8, &frame1, out_frames[1]);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "stream encode/decode roundtrip parallel" {
    const header = Header{
        .width = 2,
        .height = 2,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 2,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    const frame0 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
    };

    const frame1 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        41, 51, 61, 255,
        70, 80, 90, 255,
    };

    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStreamWithOptions(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null, .{ .parallel = true });
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;
    var out_frames = [_][]u8{ &out0, &out1 };

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    const decoded_header = try decodeStream(std.testing.allocator, &stream_reader, &out_frames);

    try std.testing.expectEqual(header.width, decoded_header.width);
    try std.testing.expectEqual(header.height, decoded_header.height);
    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);
    try std.testing.expectEqualSlices(u8, &frame0, out_frames[0]);
    try std.testing.expectEqualSlices(u8, &frame1, out_frames[1]);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "stream encode interleaves audio chunks" {
    const qoa_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "arcade.qoa", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(qoa_bytes);
    try std.testing.expect(qoa_bytes.len >= 16);
    const frame_header_bytes = qoa_bytes[8..16];

    const frame_header = try qoa_stream.parseFrameHeader(frame_header_bytes);
    const frame_size: usize = @intCast(frame_header.frame_size);
    var frame_payload = try std.testing.allocator.alloc(u8, frame_size);
    defer std.testing.allocator.free(frame_payload);

    std.mem.copyForwards(u8, frame_payload[0..8], frame_header_bytes);
    @memcpy(frame_payload[8..frame_size], qoa_bytes[16..][0 .. frame_size - 8]);

    const header = Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 2,
        .has_audio = true,
        .audio_sample_rate = frame_header.sample_rate,
        .audio_channels = frame_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 2,
    };

    const frame0 = [_]u8{ 10, 20, 30, 255 };
    const frame1 = [_]u8{ 12, 22, 32, 255 };
    const frames = [_][]const u8{ &frame0, &frame1 };

    const audio_chunks = [_][]const u8{ frame_payload, frame_payload, frame_payload };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStreamWithOptions(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null, .{ .audio_chunks = &audio_chunks });
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    const decoded_header = try readHeader(&stream_reader);
    try std.testing.expect(decoded_header.has_audio);

    const expected_types = [_]ChunkType{ .iframe, .audio, .pframe, .audio, .audio };
    for (expected_types) |expected_type| {
        const chunk_header = try readChunkHeader(&stream_reader, decoded_header.flags.frame_metadata);
        try std.testing.expectEqual(expected_type, chunk_header.chunk_type);

        const payload_size: usize = @intCast(chunk_header.payload_size);
        const payload = try std.testing.allocator.alloc(u8, payload_size);
        defer std.testing.allocator.free(payload);
        try readChunkPayload(&stream_reader, payload);

        if (expected_type == .audio) {
            try validateAudioChunkPayload(decoded_header, payload);
        }
    }

    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "stream decoder exposes audio packets" {
    const qoa_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "arcade.qoa", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(qoa_bytes);
    try std.testing.expect(qoa_bytes.len >= 16);
    const frame_header_bytes = qoa_bytes[8..16];

    const frame_header = try qoa_stream.parseFrameHeader(frame_header_bytes);
    const frame_size: usize = @intCast(frame_header.frame_size);
    var frame_payload = try std.testing.allocator.alloc(u8, frame_size);
    defer std.testing.allocator.free(frame_payload);

    std.mem.copyForwards(u8, frame_payload[0..8], frame_header_bytes);
    @memcpy(frame_payload[8..frame_size], qoa_bytes[16..][0 .. frame_size - 8]);

    const header = Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 2,
        .has_audio = true,
        .audio_sample_rate = frame_header.sample_rate,
        .audio_channels = frame_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 2,
    };

    const frame0 = [_]u8{ 10, 20, 30, 255 };
    const frame1 = [_]u8{ 12, 22, 32, 255 };
    const frames = [_][]const u8{ &frame0, &frame1 };

    const audio_chunks = [_][]const u8{ frame_payload, frame_payload, frame_payload };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStreamWithOptions(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null, .{ .audio_chunks = &audio_chunks });
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    var decoder = try StreamDecoder(@TypeOf(&stream_reader)).init(std.testing.allocator, &stream_reader);
    defer decoder.deinit();

    var frame_out: [frame0.len]u8 = undefined;
    var frame_index: usize = 0;
    var audio_count: usize = 0;

    while (true) {
        const packet = try decoder.nextPacket(&frame_out);
        if (packet == null) break;
        switch (packet.?) {
            .frame => {
                try std.testing.expect(frame_index < frames.len);
                try std.testing.expectEqualSlices(u8, frames[frame_index], &frame_out);
                frame_index += 1;
            },
            .audio => |payload| {
                try std.testing.expectEqualSlices(u8, frame_payload, payload);
                audio_count += 1;
            },
        }
    }

    try std.testing.expectEqual(@as(usize, 2), frame_index);
    try std.testing.expectEqual(@as(usize, 3), audio_count);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "stream decoder exposes frame duration metadata" {
    const header = Header{
        .width = 2,
        .height = 2,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .flags = .{ .frame_metadata = true },
        .gop_size = 2,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    const frame0 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        40, 50, 60, 255,
        70, 80, 90, 255,
    };

    const frame1 = [_]u8{
        10, 20, 30, 255,
        10, 20, 30, 255,
        41, 51, 61, 255,
        70, 80, 90, 255,
    };

    const durations = [_]u32{ 33_000, 66_000 };
    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStream(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, &durations);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    var decoder = try StreamDecoder(@TypeOf(&stream_reader)).init(std.testing.allocator, &stream_reader);
    defer decoder.deinit();

    var out0: [frame0.len]u8 = undefined;
    try std.testing.expect(try decoder.nextFrame(&out0));
    try std.testing.expectEqual(durations[0], decoder.last_frame_duration_us);

    var out1: [frame1.len]u8 = undefined;
    try std.testing.expect(try decoder.nextFrame(&out1));
    try std.testing.expectEqual(durations[1], decoder.last_frame_duration_us);
}

test "stream encode/decode roundtrip RGB-only" {
    const header = Header{
        .width = 2,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgb,
        .flags = .{ .rgb_only = true },
        .gop_size = 2,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    const frame0 = [_]u8{
        10, 20, 30,
        40, 50, 60,
    };

    const frame1 = [_]u8{
        10, 20, 30,
        42, 52, 62,
    };

    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStream(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;
    var out_frames = [_][]u8{ &out0, &out1 };

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    const decoded_header = try decodeStream(std.testing.allocator, &stream_reader, &out_frames);

    try std.testing.expectEqual(header.width, decoded_header.width);
    try std.testing.expectEqual(header.height, decoded_header.height);
    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);
    try std.testing.expectEqualSlices(u8, &frame0, out_frames[0]);
    try std.testing.expectEqualSlices(u8, &frame1, out_frames[1]);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test "stream rejects frame size mismatches" {
    const header = Header{
        .width = 2,
        .height = 2,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 1,
    };

    const frame = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
        7, 8, 9, 255,
        10, 11, 12, 255,
    };

    const bad_frame = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
        7, 8, 9, 255,
    };

    const frames = [_][]const u8{ &bad_frame };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try std.testing.expectError(QovError.FrameSizeMismatch, encodeStream(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null));

    var buffer: [header_size]u8 = undefined;
    var header_writer: std.Io.Writer = .fixed(&buffer);
    try writeHeader(&header_writer, header);

    var header_reader: std.Io.Reader = .fixed(header_writer.buffered());
    var decoder = try StreamDecoder(@TypeOf(&header_reader)).init(std.testing.allocator, &header_reader);
    defer decoder.deinit();

    var out: [frame.len]u8 = undefined;
    try std.testing.expectError(QovError.FrameSizeMismatch, decoder.nextFrame(out[0..bad_frame.len]));
}

test "stream decoder nextFrame helper" {
    const header = Header{
        .width = 2,
        .height = 1,
        .fps_num = 24,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 2,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    const frame0 = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
    };

    const frame1 = [_]u8{
        1, 2, 3, 255,
        7, 8, 9, 255,
    };

    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);

    var encoded_writer_alloc = testArrayListWriter(&encoded);
    try encodeStream(std.testing.allocator, &encoded_writer_alloc.writer, header, &frames, null);
    finishTestArrayListWriter(&encoded, &encoded_writer_alloc);

    var stream_reader: std.Io.Reader = .fixed(encoded.items);
    var decoder = try StreamDecoder(@TypeOf(&stream_reader)).init(std.testing.allocator, &stream_reader);
    defer decoder.deinit();

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;

    try std.testing.expect(try decoder.nextFrame(&out0));
    try std.testing.expect(try decoder.nextFrame(&out1));
    try std.testing.expect(!try decoder.nextFrame(&out1));

    try std.testing.expectEqualSlices(u8, &frame0, &out0);
    try std.testing.expectEqualSlices(u8, &frame1, &out1);
    try std.testing.expectEqual(encoded.items.len, stream_reader.seek);
}

test {
    _ = @import("qov_test.zig");
}
