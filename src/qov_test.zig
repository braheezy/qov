const std = @import("std");
const qov = @import("qov.zig");
const qoa_stream = @import("qoa_stream.zig");

const qoi_magic = [4]u8{ 'q', 'o', 'i', 'f' };

const QoiHeader = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

const QoiError = error{InvalidQoi};

fn readExact(reader: anytype, buf: []u8) QoiError!void {
    const amount = reader.readAll(buf) catch return QoiError.InvalidQoi;
    if (amount != buf.len) return QoiError.InvalidQoi;
}

fn readQoiHeader(reader: anytype) QoiError!QoiHeader {
    var buf: [14]u8 = undefined;
    try readExact(reader, &buf);

    if (!std.mem.eql(u8, buf[0..4], &qoi_magic)) return QoiError.InvalidQoi;

    return QoiHeader{
        .width = std.mem.readInt(u32, buf[4..8], .big),
        .height = std.mem.readInt(u32, buf[8..12], .big),
        .channels = buf[12],
        .colorspace = buf[13],
    };
}

fn loadQoiRgba(allocator: std.mem.Allocator, path: []const u8) !struct { header: QoiHeader, pixels: []u8 } {
    const file_bytes = std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize)) catch return QoiError.InvalidQoi;
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    var stream_reader = stream.reader();
    const header = try readQoiHeader(&stream_reader);

    if (header.channels != 4) return QoiError.InvalidQoi;
    if (header.width == 0 or header.height == 0) return QoiError.InvalidQoi;

    const pixel_count = std.math.mul(usize, @intCast(header.width), @intCast(header.height)) catch return QoiError.InvalidQoi;
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch return QoiError.InvalidQoi;

    const pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);

    try qov.decodeIFrame(&stream_reader, pixels);

    return .{ .header = header, .pixels = pixels };
}

test "qoi vector stream roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const paths = [_][]const u8{
        "testdata/qoi/frame_0.qoi",
        "testdata/qoi/frame_1.qoi",
        "testdata/qoi/frame_2.qoi",
    };

    var frames = std.ArrayList([]u8).empty;
    defer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }

    var width: u32 = 0;
    var height: u32 = 0;

    for (paths) |path| {
        const loaded = try loadQoiRgba(allocator, path);

        if (width == 0 and height == 0) {
            width = loaded.header.width;
            height = loaded.header.height;
        } else {
            try std.testing.expectEqual(width, loaded.header.width);
            try std.testing.expectEqual(height, loaded.header.height);
        }

        try frames.append(allocator, loaded.pixels);
    }

    const header = qov.Header{
        .width = @intCast(width),
        .height = @intCast(height),
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 30,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = @intCast(frames.items.len),
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);

    var encoded_writer = encoded.writer(allocator);
    try qov.encodeStream(allocator, &encoded_writer, header, frames.items, null);

    const out_frames = try allocator.alloc([]u8, frames.items.len);
    defer {
        for (out_frames) |frame| allocator.free(frame);
        allocator.free(out_frames);
    }

    const frame_bytes = qov.headerFrameBytes(header);
    for (out_frames) |*frame| {
        frame.* = try allocator.alloc(u8, frame_bytes);
    }

    var stream = std.io.fixedBufferStream(encoded.items);
    var stream_reader = stream.reader();
    const decoded_header = try qov.decodeStream(allocator, &stream_reader, out_frames);

    try std.testing.expectEqual(header.width, decoded_header.width);
    try std.testing.expectEqual(header.height, decoded_header.height);
    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);

    for (frames.items, 0..) |frame, index| {
        try std.testing.expectEqualSlices(u8, frame, out_frames[index]);
    }

    try std.testing.expectEqual(encoded.items.len, stream.pos);
}

test "stream encode/decode benchmark small frames" {
    const width: u32 = 64;
    const height: u32 = 64;
    const frame_count: usize = 12;
    const frame_bytes = @as(usize, width) * @as(usize, height) * 4;

    const frames = try std.testing.allocator.alloc([]u8, frame_count);
    defer {
        for (frames) |frame| std.testing.allocator.free(frame);
        std.testing.allocator.free(frames);
    }

    for (frames, 0..) |*frame, frame_index| {
        frame.* = try std.testing.allocator.alloc(u8, frame_bytes);
        const seed: u8 = @intCast((frame_index * 17) % 251);
        var offset: usize = 0;
        while (offset < frame_bytes) : (offset += 4) {
            const base: u8 = @intCast(offset % 251);
            frame.*[offset] = seed +% base;
            frame.*[offset + 1] = seed +% base +% 1;
            frame.*[offset + 2] = seed +% base +% 2;
            frame.*[offset + 3] = 255;
        }
    }

    const header = qov.Header{
        .width = width,
        .height = height,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 6,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = @intCast(frame_count),
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var encoded_writer = encoded.writer(std.testing.allocator);

    var timer = try std.time.Timer.start();
    try qov.encodeStream(std.testing.allocator, &encoded_writer, header, frames, null);

    const out_frame_bytes = qov.headerFrameBytes(header);
    const out_frames = try std.testing.allocator.alloc([]u8, frame_count);
    defer {
        for (out_frames) |frame| std.testing.allocator.free(frame);
        std.testing.allocator.free(out_frames);
    }
    for (out_frames) |*frame| {
        frame.* = try std.testing.allocator.alloc(u8, out_frame_bytes);
    }

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    const decoded_header = try qov.decodeStream(std.testing.allocator, &reader, out_frames);
    const elapsed_ns = timer.read();

    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);
    try std.testing.expectEqualSlices(u8, frames[0], out_frames[0]);
    try std.testing.expectEqualSlices(u8, frames[frame_count - 1], out_frames[frame_count - 1]);
    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
}

test "I-frame run boundary lengths" {
    const pixel = [_]u8{ 0, 0, 0, 255 };

    var pixels_62: [62 * 4]u8 = undefined;
    for (0..62) |i| {
        const base = i * 4;
        @memcpy(pixels_62[base .. base + 4], &pixel);
    }

    var encoded_62 = std.ArrayList(u8).empty;
    defer encoded_62.deinit(std.testing.allocator);

    var writer_62 = encoded_62.writer(std.testing.allocator);
    try qov.encodeIFrame(&writer_62, &pixels_62);

    try std.testing.expectEqual(@as(usize, 1 + qov.end_marker.len), encoded_62.items.len);
    try std.testing.expectEqual(@as(u8, 0b1100_0000 | 61), encoded_62.items[0]);

    var pixels_63: [63 * 4]u8 = undefined;
    for (0..63) |i| {
        const base = i * 4;
        @memcpy(pixels_63[base .. base + 4], &pixel);
    }

    var encoded_63 = std.ArrayList(u8).empty;
    defer encoded_63.deinit(std.testing.allocator);

    var writer_63 = encoded_63.writer(std.testing.allocator);
    try qov.encodeIFrame(&writer_63, &pixels_63);

    try std.testing.expectEqual(@as(usize, 2 + qov.end_marker.len), encoded_63.items.len);
    try std.testing.expectEqual(@as(u8, 0b1100_0000 | 61), encoded_63.items[0]);
    try std.testing.expectEqual(@as(u8, 0b1100_0000 | 0), encoded_63.items[1]);
}

test "P-frame trun boundary lengths" {
    var prev_256: [256 * 4]u8 = undefined;
    var pixels_256: [256 * 4]u8 = undefined;
    @memset(&prev_256, 42);
    @memcpy(&pixels_256, &prev_256);

    var encoded_256 = std.ArrayList(u8).empty;
    defer encoded_256.deinit(std.testing.allocator);

    var writer_256 = encoded_256.writer(std.testing.allocator);
    try qov.encodePFrame(&writer_256, &pixels_256, &prev_256);

    try std.testing.expectEqual(@as(usize, 2 + qov.end_marker.len), encoded_256.items.len);
    try std.testing.expectEqual(@as(u8, 0xFC), encoded_256.items[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), encoded_256.items[1]);

    var prev_257: [257 * 4]u8 = undefined;
    var pixels_257: [257 * 4]u8 = undefined;
    @memset(&prev_257, 7);
    @memcpy(&pixels_257, &prev_257);

    var encoded_257 = std.ArrayList(u8).empty;
    defer encoded_257.deinit(std.testing.allocator);

    var writer_257 = encoded_257.writer(std.testing.allocator);
    try qov.encodePFrame(&writer_257, &pixels_257, &prev_257);

    try std.testing.expectEqual(@as(usize, 4 + qov.end_marker.len), encoded_257.items.len);
    try std.testing.expectEqual(@as(u8, 0xFC), encoded_257.items[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), encoded_257.items[1]);
    try std.testing.expectEqual(@as(u8, 0xFC), encoded_257.items[2]);
    try std.testing.expectEqual(@as(u8, 0x00), encoded_257.items[3]);
}

test "stream chunk payload sizes match encoded payloads" {
    const header = qov.Header{
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

    var iframe_payload = std.ArrayList(u8).empty;
    defer iframe_payload.deinit(std.testing.allocator);
    var iframe_writer = iframe_payload.writer(std.testing.allocator);
    try qov.encodeIFrame(&iframe_writer, &frame0);

    var pframe_payload = std.ArrayList(u8).empty;
    defer pframe_payload.deinit(std.testing.allocator);
    var pframe_writer = pframe_payload.writer(std.testing.allocator);
    try qov.encodePFrame(&pframe_writer, &frame1, &frame0);

    const frames = [_][]const u8{ &frame0, &frame1 };
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var encoded_writer = encoded.writer(std.testing.allocator);
    try qov.encodeStream(std.testing.allocator, &encoded_writer, header, &frames, null);

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    _ = try qov.readHeader(&reader);

    const chunk0 = try qov.readChunkHeader(&reader, header.flags.frame_metadata);
    const chunk0_len: usize = @intCast(chunk0.payload_size);
    try std.testing.expectEqual(@as(u32, @intCast(iframe_payload.items.len)), chunk0.payload_size);
    const chunk0_payload = try std.testing.allocator.alloc(u8, chunk0_len);
    defer std.testing.allocator.free(chunk0_payload);
    try qov.readChunkPayload(&reader, chunk0_payload);
    try std.testing.expectEqual(iframe_payload.items.len, chunk0_payload.len);

    const chunk1 = try qov.readChunkHeader(&reader, header.flags.frame_metadata);
    const chunk1_len: usize = @intCast(chunk1.payload_size);
    try std.testing.expectEqual(@as(u32, @intCast(pframe_payload.items.len)), chunk1.payload_size);
    const chunk1_payload = try std.testing.allocator.alloc(u8, chunk1_len);
    defer std.testing.allocator.free(chunk1_payload);
    try qov.readChunkPayload(&reader, chunk1_payload);
    try std.testing.expectEqual(pframe_payload.items.len, chunk1_payload.len);

    try std.testing.expectEqual(encoded.items.len, stream.pos);
}

test "audio chunk helpers validate QOA payloads" {
    const header = qov.Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = true,
        .audio_sample_rate = 24000,
        .audio_channels = 2,
        .audio_frames_per_chunk = 2,
        .frame_count = 0,
    };

    const file_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "arcade.qoa", std.math.maxInt(usize));
    defer std.testing.allocator.free(file_bytes);

    var offset: usize = 8;
    var frames_seen: usize = 0;
    const frames_per_chunk: usize = @intCast(header.audio_frames_per_chunk);
    while (frames_seen < frames_per_chunk) : (frames_seen += 1) {
        const frame_header = try qoa_stream.parseFrameHeader(file_bytes[offset..]);
        const frame_size: usize = @intCast(frame_header.frame_size);
        offset += frame_size;
        try std.testing.expect(offset <= file_bytes.len);
    }

    const payload = file_bytes[8..offset];
    try qov.validateAudioChunkPayload(header, payload);

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var writer = encoded.writer(std.testing.allocator);
    try qov.writeAudioChunk(&writer, header, payload);

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    const payload_buf = try std.testing.allocator.alloc(u8, payload.len);
    defer std.testing.allocator.free(payload_buf);

    const payload_size = try qov.readAudioChunk(&reader, header, payload_buf);
    try std.testing.expectEqual(payload.len, payload_size);
    try std.testing.expectEqualSlices(u8, payload, payload_buf[0..payload_size]);
    try std.testing.expectEqual(encoded.items.len, stream.pos);
}

test "stream decode stops on EOF when frame count unknown" {
    const header = qov.Header{
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
        .frame_count = 0,
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

    var encoded_writer = encoded.writer(std.testing.allocator);
    try qov.encodeStream(std.testing.allocator, &encoded_writer, header, &frames, null);

    const frame_bytes = qov.headerFrameBytes(header);
    var out_frames = try std.testing.allocator.alloc([]u8, 4);
    defer {
        for (out_frames) |frame| std.testing.allocator.free(frame);
        std.testing.allocator.free(out_frames);
    }
    for (out_frames) |*frame| {
        frame.* = try std.testing.allocator.alloc(u8, frame_bytes);
        @memset(frame.*, 0xAA);
    }

    var stream = std.io.fixedBufferStream(encoded.items);
    var stream_reader = stream.reader();
    const decoded_header = try qov.decodeStream(std.testing.allocator, &stream_reader, out_frames);

    try std.testing.expectEqual(@as(u32, 0), decoded_header.frame_count);
    try std.testing.expectEqualSlices(u8, &frame0, out_frames[0]);
    try std.testing.expectEqualSlices(u8, &frame1, out_frames[1]);
    for (out_frames[2..]) |frame| {
        for (frame) |byte| {
            try std.testing.expectEqual(@as(u8, 0xAA), byte);
        }
    }
    try std.testing.expectEqual(encoded.items.len, stream.pos);
}

test "frame end marker detection" {
    const pixels = [_]u8{
        0, 0, 0, 255,
    };

    var iframe_payload = std.ArrayList(u8).empty;
    defer iframe_payload.deinit(std.testing.allocator);
    var iframe_writer = iframe_payload.writer(std.testing.allocator);
    try qov.encodeIFrame(&iframe_writer, &pixels);
    iframe_payload.items[iframe_payload.items.len - 1] = 0;

    var out_pixels: [pixels.len]u8 = undefined;
    var iframe_stream = std.io.fixedBufferStream(iframe_payload.items);
    var iframe_reader = iframe_stream.reader();
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.decodeIFrame(&iframe_reader, &out_pixels));

    var pframe_payload = std.ArrayList(u8).empty;
    defer pframe_payload.deinit(std.testing.allocator);
    var pframe_writer = pframe_payload.writer(std.testing.allocator);
    try qov.encodePFrame(&pframe_writer, &pixels, &pixels);
    pframe_payload.items[pframe_payload.items.len - 1] = 0;

    var pframe_out: [pixels.len]u8 = undefined;
    var pframe_stream = std.io.fixedBufferStream(pframe_payload.items);
    var pframe_reader = pframe_stream.reader();
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.decodePFrame(&pframe_reader, &pframe_out, &pixels));
}

test "malformed headers are rejected" {
    const header = qov.Header{
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

    var buffer: [qov.header_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();
    try qov.writeHeader(&writer, header);

    buffer[0] = 'x';
    stream.pos = 0;
    var reader = stream.reader();
    try std.testing.expectError(qov.QovError.InvalidMagic, qov.readHeader(&reader));

    @memcpy(buffer[0..4], &qov.magic);
    buffer[4] = 99;
    stream.pos = 0;
    reader = stream.reader();
    try std.testing.expectError(qov.QovError.UnsupportedVersion, qov.readHeader(&reader));

    @memcpy(buffer[0..4], &qov.magic);
    buffer[4] = qov.version;
    @memset(buffer[11..13], 0);
    stream.pos = 0;
    reader = stream.reader();
    try std.testing.expectError(qov.QovError.InvalidHeader, qov.readHeader(&reader));

    const truncated = buffer[0..10];
    var short_stream = std.io.fixedBufferStream(truncated);
    var short_reader = short_stream.reader();
    try std.testing.expectError(qov.QovError.UnexpectedEof, qov.readHeader(&short_reader));
}

test "unknown chunk types fail decoding" {
    const header = qov.Header{
        .width = 1,
        .height = 1,
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

    var buffer: [qov.header_size + qov.chunk_header_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();
    try qov.writeHeader(&writer, header);

    buffer[qov.header_size] = 9;
    std.mem.writeInt(u32, buffer[qov.header_size + 1 .. qov.header_size + 5], 0, .big);

    stream.pos = 0;
    var reader = stream.reader();
    _ = try qov.readHeader(&reader);
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.readChunkHeader(&reader, false));
}

test "truncated streams error during decode" {
    const header = qov.Header{
        .width = 1,
        .height = 1,
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
    };

    const frames = [_][]const u8{ &frame };
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var writer = encoded.writer(std.testing.allocator);
    try qov.encodeStream(std.testing.allocator, &writer, header, &frames, null);

    const truncated = encoded.items[0 .. encoded.items.len - 1];
    var out_frame: [frame.len]u8 = undefined;
    var out_frames = [_][]u8{ &out_frame };
    var stream = std.io.fixedBufferStream(truncated);
    var reader = stream.reader();
    try std.testing.expectError(qov.QovError.UnexpectedEof, qov.decodeStream(std.testing.allocator, &reader, &out_frames));
}

test "in-memory example encode/decode roundtrip" {
    const header = qov.Header{
        .width = 2,
        .height = 1,
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
        0x12, 0x34, 0x56, 0xFF,
        0xAA, 0xBB, 0xCC, 0xFF,
    };
    const frame1 = [_]u8{
        0xDE, 0xAD, 0xBE, 0xEF,
        0x00, 0x11, 0x22, 0xFF,
    };
    const frames = [_][]const u8{ &frame0, &frame1 };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var writer = encoded.writer(std.testing.allocator);
    try qov.encodeStream(std.testing.allocator, &writer, header, &frames, null);

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;
    var out_frames = [_][]u8{ &out0, &out1 };
    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    _ = try qov.decodeStream(std.testing.allocator, &reader, &out_frames);

    try std.testing.expectEqualSlices(u8, &frame0, &out0);
    try std.testing.expectEqualSlices(u8, &frame1, &out1);
    try std.testing.expectEqual(encoded.items.len, stream.pos);
}

test "audio header validation rejects invalid configs" {
    const valid_audio_header = qov.Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = true,
        .audio_sample_rate = 48000,
        .audio_channels = 2,
        .audio_frames_per_chunk = 1,
        .frame_count = 0,
    };
    try qov.validateHeader(valid_audio_header);

    var no_sample_rate = valid_audio_header;
    no_sample_rate.audio_sample_rate = 0;
    try std.testing.expectError(qov.QovError.InvalidHeader, qov.validateHeader(no_sample_rate));

    var no_channels = valid_audio_header;
    no_channels.audio_channels = 0;
    try std.testing.expectError(qov.QovError.InvalidHeader, qov.validateHeader(no_channels));

    var no_frames_per_chunk = valid_audio_header;
    no_frames_per_chunk.audio_frames_per_chunk = 0;
    try std.testing.expectError(qov.QovError.InvalidHeader, qov.validateHeader(no_frames_per_chunk));

    var audio_without_flag = valid_audio_header;
    audio_without_flag.has_audio = false;
    try std.testing.expectError(qov.QovError.InvalidHeader, qov.validateHeader(audio_without_flag));
}

test "audio chunk validation rejects mismatched params" {
    const file_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "arcade.qoa", std.math.maxInt(usize));
    defer std.testing.allocator.free(file_bytes);

    const frame_header = try qoa_stream.parseFrameHeader(file_bytes[8..]);
    const frame_size: usize = @intCast(frame_header.frame_size);
    const payload = file_bytes[8 .. 8 + frame_size];

    const header = qov.Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = true,
        .audio_sample_rate = frame_header.sample_rate,
        .audio_channels = frame_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 0,
    };
    try qov.validateAudioChunkPayload(header, payload);

    var wrong_sample_rate = header;
    wrong_sample_rate.audio_sample_rate = 44100;
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.validateAudioChunkPayload(wrong_sample_rate, payload));

    var wrong_channels = header;
    wrong_channels.audio_channels = 1;
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.validateAudioChunkPayload(wrong_channels, payload));

    var wrong_frame_count = header;
    wrong_frame_count.audio_frames_per_chunk = 2;
    try std.testing.expectError(qov.QovError.InvalidChunk, qov.validateAudioChunkPayload(wrong_frame_count, payload));
}

test "stream decoder returns audio packets via nextPacket" {
    const file_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "arcade.qoa", std.math.maxInt(usize));
    defer std.testing.allocator.free(file_bytes);

    const frame_header = try qoa_stream.parseFrameHeader(file_bytes[8..]);
    const frame_size: usize = @intCast(frame_header.frame_size);
    const audio_payload = file_bytes[8 .. 8 + frame_size];

    const frame0 = [_]u8{ 0x10, 0x20, 0x30, 0xFF };
    const frames = [_][]const u8{&frame0};

    const header = qov.Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = true,
        .audio_sample_rate = frame_header.sample_rate,
        .audio_channels = frame_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 1,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var writer = encoded.writer(std.testing.allocator);
    try qov.encodeStreamWithOptions(std.testing.allocator, &writer, header, &frames, null, .{
        .audio_chunks = &[_][]const u8{audio_payload},
    });

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    var decoder = try qov.StreamDecoder(@TypeOf(&reader)).init(std.testing.allocator, &reader);
    defer decoder.deinit();

    var out_frame: [frame0.len]u8 = undefined;
    var audio_seen = false;
    var frame_seen = false;

    while (true) {
        const packet = try decoder.nextPacket(&out_frame);
        if (packet == null) break;

        switch (packet.?) {
            .frame => frame_seen = true,
            .audio => |data| {
                audio_seen = true;
                try std.testing.expectEqualSlices(u8, audio_payload, data);
            },
        }
    }

    try std.testing.expect(audio_seen);
    try std.testing.expect(frame_seen);
    try std.testing.expectEqualSlices(u8, &frame0, &out_frame);
}

test "stream decode handles audio longer than video" {
    const file_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "arcade.qoa", std.math.maxInt(usize));
    defer std.testing.allocator.free(file_bytes);

    var audio_chunks = std.ArrayList([]const u8).empty;
    defer audio_chunks.deinit(std.testing.allocator);

    var offset: usize = 8;
    var frame_header = try qoa_stream.parseFrameHeader(file_bytes[offset..]);
    while (audio_chunks.items.len < 3) {
        const frame_size: usize = @intCast(frame_header.frame_size);
        if (offset + frame_size > file_bytes.len) break;
        try audio_chunks.append(std.testing.allocator, file_bytes[offset .. offset + frame_size]);
        offset += frame_size;
        if (offset + 8 <= file_bytes.len) {
            frame_header = try qoa_stream.parseFrameHeader(file_bytes[offset..]);
        }
    }

    const first_frame_header = try qoa_stream.parseFrameHeader(audio_chunks.items[0]);

    const frame0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xFF };
    const frames = [_][]const u8{&frame0};

    const header = qov.Header{
        .width = 1,
        .height = 1,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 1,
        .has_audio = true,
        .audio_sample_rate = first_frame_header.sample_rate,
        .audio_channels = first_frame_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 1,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(std.testing.allocator);
    var writer = encoded.writer(std.testing.allocator);
    try qov.encodeStreamWithOptions(std.testing.allocator, &writer, header, &frames, null, .{
        .audio_chunks = audio_chunks.items,
    });

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    var decoder = try qov.StreamDecoder(@TypeOf(&reader)).init(std.testing.allocator, &reader);
    defer decoder.deinit();

    var out_frame: [frame0.len]u8 = undefined;
    var audio_count: usize = 0;
    var frame_count: usize = 0;

    while (true) {
        const packet = try decoder.nextPacket(&out_frame);
        if (packet == null) break;

        switch (packet.?) {
            .frame => frame_count += 1,
            .audio => audio_count += 1,
        }
    }

    try std.testing.expectEqual(@as(usize, 1), frame_count);
    try std.testing.expectEqual(@as(usize, 3), audio_count);
}

test "end-to-end encode/decode with arcade.qoa audio roundtrip" {
    const allocator = std.testing.allocator;

    const qoa_bytes = try std.fs.cwd().readFileAlloc(allocator, "arcade.qoa", std.math.maxInt(usize));
    defer allocator.free(qoa_bytes);

    var audio_chunks = std.ArrayList([]const u8).empty;
    defer audio_chunks.deinit(allocator);

    var qoa_offset: usize = 8;
    const first_qoa_header = try qoa_stream.parseFrameHeader(qoa_bytes[qoa_offset..]);
    const num_audio_chunks = 5;
    while (audio_chunks.items.len < num_audio_chunks and qoa_offset + 8 <= qoa_bytes.len) {
        const fh = try qoa_stream.parseFrameHeader(qoa_bytes[qoa_offset..]);
        const frame_size: usize = @intCast(fh.frame_size);
        if (qoa_offset + frame_size > qoa_bytes.len) break;
        try audio_chunks.append(allocator, qoa_bytes[qoa_offset .. qoa_offset + frame_size]);
        qoa_offset += frame_size;
    }

    const qoi_frame0 = try std.fs.cwd().readFileAlloc(allocator, "testdata/qoi/frame_0.qoi", std.math.maxInt(usize));
    defer allocator.free(qoi_frame0);
    const qoi_frame1 = try std.fs.cwd().readFileAlloc(allocator, "testdata/qoi/frame_1.qoi", std.math.maxInt(usize));
    defer allocator.free(qoi_frame1);
    const qoi_frame2 = try std.fs.cwd().readFileAlloc(allocator, "testdata/qoi/frame_2.qoi", std.math.maxInt(usize));
    defer allocator.free(qoi_frame2);

    const frame0 = try loadQoiRgba(allocator, "testdata/qoi/frame_0.qoi");
    defer allocator.free(frame0.pixels);
    const frame1 = try loadQoiRgba(allocator, "testdata/qoi/frame_1.qoi");
    defer allocator.free(frame1.pixels);
    const frame2 = try loadQoiRgba(allocator, "testdata/qoi/frame_2.qoi");
    defer allocator.free(frame2.pixels);

    const frames = [_][]const u8{ frame0.pixels, frame1.pixels, frame2.pixels };

    const header = qov.Header{
        .width = @intCast(frame0.header.width),
        .height = @intCast(frame0.header.height),
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 3,
        .has_audio = true,
        .audio_sample_rate = first_qoa_header.sample_rate,
        .audio_channels = first_qoa_header.channels,
        .audio_frames_per_chunk = 1,
        .frame_count = 3,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    var writer = encoded.writer(allocator);
    try qov.encodeStreamWithOptions(allocator, &writer, header, &frames, null, .{
        .audio_chunks = audio_chunks.items,
    });

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();
    var decoder = try qov.StreamDecoder(@TypeOf(&reader)).init(allocator, &reader);
    defer decoder.deinit();

    try std.testing.expectEqual(header.width, decoder.header.width);
    try std.testing.expectEqual(header.height, decoder.header.height);
    try std.testing.expect(decoder.header.has_audio);
    try std.testing.expectEqual(first_qoa_header.sample_rate, decoder.header.audio_sample_rate);
    try std.testing.expectEqual(first_qoa_header.channels, decoder.header.audio_channels);

    const frame_bytes = qov.headerFrameBytes(decoder.header);
    const out_frame = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(out_frame);

    var decoded_audio = std.ArrayList([]u8).empty;
    defer {
        for (decoded_audio.items) |chunk| allocator.free(chunk);
        decoded_audio.deinit(allocator);
    }

    var video_count: usize = 0;
    const expected_frames = [_][]const u8{ frame0.pixels, frame1.pixels, frame2.pixels };

    while (true) {
        const packet = try decoder.nextPacket(out_frame);
        if (packet == null) break;

        switch (packet.?) {
            .frame => {
                try std.testing.expectEqualSlices(u8, expected_frames[video_count], out_frame);
                video_count += 1;
            },
            .audio => |data| {
                const chunk_copy = try allocator.dupe(u8, data);
                try decoded_audio.append(allocator, chunk_copy);
            },
        }
    }

    try std.testing.expectEqual(@as(usize, 3), video_count);
    try std.testing.expectEqual(num_audio_chunks, decoded_audio.items.len);

    for (audio_chunks.items, 0..) |original, i| {
        try std.testing.expectEqualSlices(u8, original, decoded_audio.items[i]);
    }
}
