/// QOV command-line interface.
/// Usage:
///   qov encode [--audio input.qoa] <output.qov> <input1.qoi> [input2.qoi ...]
///   qov decode [--audio output.qoa] <input.qov> <output_dir>
///   qov info <input.qov>
/// Example:
///   qov encode anim.qov frame_000.qoi frame_001.qoi
///   qov decode --audio out.qoa anim.qov frames/
///   qov info anim.qov
const std = @import("std");
const qov = @import("qov");

const qoi_magic = [4]u8{ 'q', 'o', 'i', 'f' };
const qoi_end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

const QoiHeader = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

const CliError = error{
    InvalidArgs,
    InvalidQoi,
    InvalidQoa,
    UnsupportedQoi,
    FrameSizeMismatch,
    InvalidQov,
    StreamingNotSupported,
};

const FrameInfo = struct {
    index: usize,
    chunk_type: qov.ChunkType,
    payload_size: u32,
    frame_duration_us: u32,
};

/// CLI entry point that dispatches subcommands.
pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    runMain(allocator) catch |err| {
        if (!isReportedError(err)) {
            printStderr("error: {s}\n", .{@errorName(err)}) catch {};
        }
        std.process.exit(1);
    };
}

fn runMain(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return CliError.InvalidArgs;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "encode")) {
        if (args.len < 4) {
            try printUsage();
            return CliError.InvalidArgs;
        }
        const encode_args = try parseEncodeArgs(args[2..]);
        try runEncode(allocator, encode_args.output_path, encode_args.input_paths, encode_args.audio_path);
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len < 4) {
            try printUsage();
            return CliError.InvalidArgs;
        }
        const decode_args = try parseDecodeArgs(args[2..]);
        try runDecode(allocator, decode_args.input_path, decode_args.output_dir, decode_args.audio_path);
    } else if (std.mem.eql(u8, command, "info")) {
        if (args.len != 3) {
            try printUsage();
            return CliError.InvalidArgs;
        }
        try runInfo(allocator, args[2]);
    } else {
        try printUsage();
        return CliError.InvalidArgs;
    }
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&stderr_buf);
    defer err.interface.flush() catch {};
    try err.interface.print(fmt, args);
}

fn printUsage() !void {
    try printStderr(
        "Usage:\n" ++
            "  qov encode [--audio input.qoa] <output.qov> <input1.qoi> [input2.qoi ...]\n" ++
            "  qov decode [--audio output.qoa] <input.qov> <output_dir>\n" ++
            "  qov info <input.qov>\n",
        .{},
    );
}

fn isReportedError(err: anyerror) bool {
    return err == CliError.InvalidArgs or
        err == CliError.InvalidQoi or
        err == CliError.InvalidQoa or
        err == CliError.UnsupportedQoi or
        err == CliError.FrameSizeMismatch;
}

const EncodeArgs = struct {
    output_path: []const u8,
    input_paths: []const []const u8,
    audio_path: ?[]const u8,
};

const DecodeArgs = struct {
    input_path: []const u8,
    output_dir: []const u8,
    audio_path: ?[]const u8,
};

const AudioPayloads = struct {
    bytes: []u8,
    chunks: []const []const u8,
    sample_rate: u32,
    channels: u8,
    frames_per_chunk: u16,

    fn deinit(self: *AudioPayloads, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.chunks);
        self.* = undefined;
    }
};

fn parseEncodeArgs(args: []const []const u8) !EncodeArgs {
    var index: usize = 0;
    var audio_path: ?[]const u8 = null;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--audio") or std.mem.eql(u8, arg, "-a")) {
            if (audio_path != null) return CliError.InvalidArgs;
            index += 1;
            if (index >= args.len) return CliError.InvalidArgs;
            audio_path = args[index];
            continue;
        }
        break;
    }

    if (index >= args.len) return CliError.InvalidArgs;
    const output_path = args[index];
    index += 1;
    if (index >= args.len) return CliError.InvalidArgs;

    return .{
        .output_path = output_path,
        .input_paths = args[index..],
        .audio_path = audio_path,
    };
}

fn parseDecodeArgs(args: []const []const u8) !DecodeArgs {
    var index: usize = 0;
    var audio_path: ?[]const u8 = null;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--audio") or std.mem.eql(u8, arg, "-a")) {
            if (audio_path != null) return CliError.InvalidArgs;
            index += 1;
            if (index >= args.len) return CliError.InvalidArgs;
            audio_path = args[index];
            continue;
        }
        break;
    }

    if (index >= args.len) return CliError.InvalidArgs;
    const input_path = args[index];
    index += 1;
    if (index >= args.len) return CliError.InvalidArgs;
    const output_dir = args[index];
    index += 1;
    if (index != args.len) return CliError.InvalidArgs;

    return .{
        .input_path = input_path,
        .output_dir = output_dir,
        .audio_path = audio_path,
    };
}

fn runEncode(allocator: std.mem.Allocator, output_path: []const u8, input_paths: []const []const u8, audio_path: ?[]const u8) !void {
    var frames = std.ArrayList([]u8).empty;
    defer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var base_path: []const u8 = "";

    for (input_paths) |path| {
        const file_bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(file_bytes);

        const decoded = decodeQoiToRgba(allocator, file_bytes) catch |err| {
            try reportInvalidQoi(path, err);
            if (err == CliError.UnsupportedQoi) return CliError.UnsupportedQoi;
            return CliError.InvalidQoi;
        };
        errdefer allocator.free(decoded.pixels);

        if (width == 0 and height == 0) {
            width = decoded.header.width;
            height = decoded.header.height;
            base_path = path;
        } else if (decoded.header.width != width or decoded.header.height != height) {
            allocator.free(decoded.pixels);
            try reportFrameSizeMismatch(base_path, path, width, height, decoded.header.width, decoded.header.height);
            return CliError.FrameSizeMismatch;
        }

        try frames.append(allocator, decoded.pixels);
    }

    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) {
        return CliError.InvalidQov;
    }

    var audio_payloads: ?AudioPayloads = null;
    defer if (audio_payloads) |*payloads| payloads.deinit(allocator);

    if (audio_path) |path| {
        audio_payloads = loadQoaAudio(allocator, path) catch |err| {
            if (err == CliError.InvalidQoa) {
                try reportInvalidQoa(path);
            }
            return err;
        };
    }

    var header = qov.Header{
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

    var encode_options = qov.EncodeOptions{};
    if (audio_payloads) |payloads| {
        header.has_audio = true;
        header.audio_sample_rate = payloads.sample_rate;
        header.audio_channels = payloads.channels;
        header.audio_frames_per_chunk = payloads.frames_per_chunk;
        encode_options.audio_chunks = payloads.chunks;
    }

    var out_file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [8192]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    try qov.encodeStreamWithOptions(allocator, &out_writer.interface, header, frames.items, null, encode_options);
    try out_writer.interface.flush();
}

fn runDecode(allocator: std.mem.Allocator, input_path: []const u8, output_dir: []const u8, audio_path: ?[]const u8) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(usize));
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    var stream_reader = stream.reader();
    var decoder = try qov.StreamDecoder(@TypeOf(&stream_reader)).init(allocator, &stream_reader);
    defer decoder.deinit();

    const header = decoder.header;
    if (header.frame_count == 0) return CliError.StreamingNotSupported;

    try std.fs.cwd().makePath(output_dir);

    const frame_bytes = qov.headerFrameBytes(header);
    const frame = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(frame);

    const rgb_only = qov.isRgbOnly(header);
    var rgba_frame: ?[]u8 = null;
    defer if (rgba_frame) |buffer| allocator.free(buffer);
    if (rgb_only) {
        const rgba_bytes = @as(usize, header.width) * @as(usize, header.height) * 4;
        rgba_frame = try allocator.alloc(u8, rgba_bytes);
    }

    var audio_chunks = std.ArrayList([]const u8).empty;
    defer audio_chunks.deinit(allocator);

    var frame_index: usize = 0;
    while (true) {
        const packet = try decoder.nextPacket(frame);
        if (packet == null) break;

        switch (packet.?) {
            .frame => {
                const filename = try std.fmt.allocPrint(allocator, "{s}/frame_{d:0>6}.qoi", .{ output_dir, frame_index });
                defer allocator.free(filename);

                var out_file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
                defer out_file.close();

                var out_buf: [4096]u8 = undefined;
                var out_writer = out_file.writer(&out_buf);
                const output_frame = if (rgb_only) blk: {
                    const rgba = rgba_frame orelse return CliError.InvalidQov;
                    expandRgbToRgba(rgba, frame);
                    break :blk rgba;
                } else frame;
                try writeQoi(&out_writer.interface, header.width, header.height, output_frame);
                try out_writer.interface.flush();
                frame_index += 1;
            },
            .audio => |audio_data| {
                if (audio_path != null) {
                    const chunk_copy = try allocator.dupe(u8, audio_data);
                    try audio_chunks.append(allocator, chunk_copy);
                }
            },
        }
    }

    if (audio_path) |path| {
        if (header.has_audio and audio_chunks.items.len > 0) {
            try writeQoaFile(allocator, path, header, audio_chunks.items);
        }
        for (audio_chunks.items) |chunk| allocator.free(@constCast(chunk));
    }
}

fn writeQoaFile(allocator: std.mem.Allocator, path: []const u8, header: qov.Header, audio_chunks: []const []const u8) !void {
    var total_samples: u64 = 0;
    for (audio_chunks) |chunk| {
        var offset: usize = 0;
        while (offset < chunk.len) {
            const frame_header = try qov.parseQoaFrameHeader(chunk[offset..]);
            total_samples += @as(u64, frame_header.frame_length);
            offset += @as(usize, frame_header.frame_size);
        }
    }

    if (total_samples > std.math.maxInt(u32)) return CliError.InvalidQoa;

    var out_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [8192]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);

    var qoa_header: [8]u8 = undefined;
    @memcpy(qoa_header[0..4], "qoaf");
    std.mem.writeInt(u32, qoa_header[4..8], @intCast(total_samples), .big);
    try out_writer.interface.writeAll(&qoa_header);

    for (audio_chunks) |chunk| {
        try out_writer.interface.writeAll(chunk);
    }
    try out_writer.interface.flush();
    _ = allocator;
    _ = header;
}

fn runInfo(allocator: std.mem.Allocator, input_path: []const u8) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(usize));
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    var stream_reader = stream.reader();
    const header = try qov.readHeader(&stream_reader);
    const frame_infos = try collectFrameMetadata(allocator, &stream_reader, header);
    defer allocator.free(frame_infos);

    var stdout_buf: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&stdout_buf);
    defer out.interface.flush() catch {};
    try writeInfo(&out.interface, header, frame_infos);
}

fn reportInvalidQoi(path: []const u8, err: anyerror) !void {
    const reason = describeQoiError(err);
    try printStderr("error: invalid QOI input '{s}': {s}\n", .{ path, reason });
}

fn reportInvalidQoa(path: []const u8) !void {
    try printStderr("error: invalid QOA input '{s}'\n", .{ path });
}

fn reportFrameSizeMismatch(base_path: []const u8, path: []const u8, expected_width: u32, expected_height: u32, actual_width: u32, actual_height: u32) !void {
    var stderr_buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&stderr_buf);
    defer err.interface.flush() catch {};
    try writeFrameSizeMismatch(&err.interface, base_path, path, expected_width, expected_height, actual_width, actual_height);
}

fn writeFrameSizeMismatch(writer: anytype, base_path: []const u8, path: []const u8, expected_width: u32, expected_height: u32, actual_width: u32, actual_height: u32) !void {
    if (base_path.len == 0) {
        try writer.print(
            "error: frame size mismatch for '{s}': expected {d}x{d}, got {d}x{d}\n",
            .{ path, expected_width, expected_height, actual_width, actual_height },
        );
        return;
    }
    try writer.print(
        "error: frame size mismatch for '{s}': expected {d}x{d} (from '{s}'), got {d}x{d}\n",
        .{ path, expected_width, expected_height, base_path, actual_width, actual_height },
    );
}

fn describeQoiError(err: anyerror) []const u8 {
    return switch (err) {
        CliError.InvalidQoi => "invalid QOI header",
        CliError.UnsupportedQoi => "unsupported QOI channels/colorspace",
        qov.QovError.InvalidChunk => "invalid QOI data chunk",
        qov.QovError.UnexpectedEof => "unexpected EOF while reading QOI data",
        else => "invalid QOI data",
    };
}

fn decodeQoiToRgba(allocator: std.mem.Allocator, file_bytes: []const u8) !struct { header: QoiHeader, pixels: []u8 } {
    var stream = std.io.fixedBufferStream(file_bytes);
    var stream_reader = stream.reader();
    const header = try readQoiHeader(&stream_reader);

    if (header.channels != 3 and header.channels != 4) return CliError.UnsupportedQoi;
    if (header.width == 0 or header.height == 0) return CliError.InvalidQoi;

    const pixel_count = try std.math.mul(usize, @intCast(header.width), @intCast(header.height));
    const pixel_bytes = try std.math.mul(usize, pixel_count, 4);

    const pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);

    try qov.decodeIFrame(&stream_reader, pixels);
    if (stream.pos != file_bytes.len) return CliError.InvalidQoi;

    return .{ .header = header, .pixels = pixels };
}

fn readQoiHeader(reader: anytype) !QoiHeader {
    var buf: [14]u8 = undefined;
    try readExact(reader, &buf);

    if (!std.mem.eql(u8, buf[0..4], &qoi_magic)) return CliError.InvalidQoi;

    return QoiHeader{
        .width = std.mem.readInt(u32, buf[4..8], .big),
        .height = std.mem.readInt(u32, buf[8..12], .big),
        .channels = buf[12],
        .colorspace = buf[13],
    };
}

fn writeQoi(writer: anytype, width: u16, height: u16, pixels: []const u8) !void {
    if (pixels.len % 4 != 0) return CliError.InvalidQoi;

    const header = QoiHeader{
        .width = width,
        .height = height,
        .channels = 4,
        .colorspace = 0,
    };

    try writeQoiHeader(writer, header);
    try qov.encodeIFrame(writer, pixels);
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

fn writeQoiHeader(writer: anytype, header: QoiHeader) !void {
    var buf: [14]u8 = undefined;
    @memcpy(buf[0..4], &qoi_magic);
    std.mem.writeInt(u32, buf[4..8], header.width, .big);
    std.mem.writeInt(u32, buf[8..12], header.height, .big);
    buf[12] = header.channels;
    buf[13] = header.colorspace;
    try writer.writeAll(&buf);
}

fn readExact(reader: anytype, buf: []u8) !void {
    const amount = try reader.readAll(buf);
    if (amount != buf.len) return CliError.InvalidQoi;
}

fn loadQoaAudio(allocator: std.mem.Allocator, path: []const u8) !AudioPayloads {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    errdefer allocator.free(file_bytes);

    if (file_bytes.len < 8) return CliError.InvalidQoa;
    if (!std.mem.eql(u8, file_bytes[0..4], "qoaf")) return CliError.InvalidQoa;

    const total_samples = std.mem.readInt(u32, file_bytes[4..8], .big);
    if (total_samples == 0) return CliError.InvalidQoa;

    var chunks = std.ArrayList([]const u8).empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 8;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;
    while (offset < file_bytes.len) {
        if (offset + 8 > file_bytes.len) return CliError.InvalidQoa;
        const frame_header = qov.parseQoaFrameHeader(file_bytes[offset..]) catch {
            return CliError.InvalidQoa;
        };
        if (frame_header.frame_size < 8) return CliError.InvalidQoa;

        const frame_size: usize = @intCast(frame_header.frame_size);
        if (offset + frame_size > file_bytes.len) return CliError.InvalidQoa;

        if (channels == 0) {
            channels = frame_header.channels;
            sample_rate = frame_header.sample_rate;
        } else if (channels != frame_header.channels or sample_rate != frame_header.sample_rate) {
            return CliError.InvalidQoa;
        }

        try chunks.append(allocator, file_bytes[offset .. offset + frame_size]);
        offset += frame_size;
    }
    if (offset != file_bytes.len) return CliError.InvalidQoa;
    if (channels == 0 or sample_rate == 0) return CliError.InvalidQoa;

    return .{
        .bytes = file_bytes,
        .chunks = try chunks.toOwnedSlice(allocator),
        .sample_rate = sample_rate,
        .channels = channels,
        .frames_per_chunk = 1,
    };
}

fn collectFrameMetadata(allocator: std.mem.Allocator, reader: anytype, header: qov.Header) ![]FrameInfo {
    var infos = std.ArrayList(FrameInfo).empty;
    errdefer infos.deinit(allocator);
    var index: usize = 0;
    var scratch: [4096]u8 = undefined;

    while (true) {
        if (header.frame_count != 0 and index >= header.frame_count) break;

        const chunk_header = qov.readChunkHeader(reader, header.flags.frame_metadata) catch |err| switch (err) {
            qov.QovError.UnexpectedEof => {
                if (header.frame_count == 0) break;
                return err;
            },
            else => return err,
        };

        try infos.append(allocator, .{
            .index = index,
            .chunk_type = chunk_header.chunk_type,
            .payload_size = chunk_header.payload_size,
            .frame_duration_us = chunk_header.frame_duration_us,
        });

        var remaining: usize = @intCast(chunk_header.payload_size);
        while (remaining > 0) {
            const to_read = @min(remaining, scratch.len);
            try qov.readChunkPayload(reader, scratch[0..to_read]);
            remaining -= to_read;
        }

        index += 1;
    }

    return try infos.toOwnedSlice(allocator);
}

fn writeInfo(writer: anytype, header: qov.Header, frame_infos: []const FrameInfo) !void {
    try writer.print("Header:\n", .{});
    try writer.print("  size: {d}x{d}\n", .{ header.width, header.height });
    try writer.print("  fps: {d}/{d}\n", .{ header.fps_num, header.fps_den });
    try writer.print("  colorspace: {s}\n", .{ @tagName(header.colorspace) });
    try writer.print("  channels: {s}\n", .{ @tagName(header.channels) });
    try writer.print("  flags: rgb_only={any}, frame_metadata={any}\n", .{ header.flags.rgb_only, header.flags.frame_metadata });
    try writer.print("  gop_size: {d}\n", .{ header.gop_size });
    try writer.print("  has_audio: {any}\n", .{ header.has_audio });
    try writer.print("  audio_sample_rate: {d}\n", .{ header.audio_sample_rate });
    try writer.print("  audio_channels: {d}\n", .{ header.audio_channels });
    try writer.print("  frame_count: {d}\n", .{ header.frame_count });

    try writer.print("Frames:\n", .{});
    try writer.print("  count: {d}\n", .{ frame_infos.len });
    if (!header.flags.frame_metadata) {
        try writer.print("  frame_duration_us: disabled\n", .{});
    }
    for (frame_infos) |info| {
        if (header.flags.frame_metadata) {
            try writer.print(
                "  [{d}] type={s} payload_bytes={d} duration_us={d}\n",
                .{ info.index, @tagName(info.chunk_type), info.payload_size, info.frame_duration_us },
            );
        } else {
            try writer.print(
                "  [{d}] type={s} payload_bytes={d}\n",
                .{ info.index, @tagName(info.chunk_type), info.payload_size },
            );
        }
    }
}

test "qoi read/write roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pixels = [_]u8{
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0x80,
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var buffer_writer = buffer.writer(allocator);
    try writeQoi(&buffer_writer, 2, 1, &pixels);

    const decoded = try decodeQoiToRgba(allocator, buffer.items);
    defer allocator.free(decoded.pixels);

    try std.testing.expectEqual(@as(u32, 2), decoded.header.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.header.height);
    try std.testing.expectEqual(@as(u8, 4), decoded.header.channels);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}

test "cli QOI error descriptions" {
    try std.testing.expectEqualStrings("invalid QOI header", describeQoiError(CliError.InvalidQoi));
    try std.testing.expectEqualStrings("unsupported QOI channels/colorspace", describeQoiError(CliError.UnsupportedQoi));
    try std.testing.expectEqualStrings("invalid QOI data chunk", describeQoiError(qov.QovError.InvalidChunk));
    try std.testing.expectEqualStrings("unexpected EOF while reading QOI data", describeQoiError(qov.QovError.UnexpectedEof));
}

test "cli reads QOA audio metadata" {
    var audio = try loadQoaAudio(std.testing.allocator, "arcade.qoa");
    defer audio.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 24000), audio.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), audio.channels);
    try std.testing.expectEqual(@as(u16, 1), audio.frames_per_chunk);
    try std.testing.expect(audio.chunks.len > 0);
}

test "cli frame size mismatch message includes sizes" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    var writer = buffer.writer(std.testing.allocator);
    try writeFrameSizeMismatch(&writer, "first.qoi", "second.qoi", 10, 12, 14, 16);
    try std.testing.expectEqualStrings(
        "error: frame size mismatch for 'second.qoi': expected 10x12 (from 'first.qoi'), got 14x16\n",
        buffer.items,
    );
}

test "cli info output includes frame metadata" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const header = qov.Header{
        .width = 2,
        .height = 3,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .flags = .{ .frame_metadata = true },
        .gop_size = 4,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 2,
    };

    var writer = buffer.writer(std.testing.allocator);
    try qov.writeHeader(&writer, header);
    try qov.writeChunkHeader(&writer, .{
        .chunk_type = .iframe,
        .payload_size = 2,
        .frame_duration_us = 10,
    }, true);
    try writer.writeAll(&[_]u8{ 0x01, 0x02 });
    try qov.writeChunkHeader(&writer, .{
        .chunk_type = .pframe,
        .payload_size = 3,
        .frame_duration_us = 20,
    }, true);
    try writer.writeAll(&[_]u8{ 0x03, 0x04, 0x05 });

    var stream = std.io.fixedBufferStream(buffer.items);
    var stream_reader = stream.reader();
    const parsed_header = try qov.readHeader(&stream_reader);
    const frame_infos = try collectFrameMetadata(std.testing.allocator, &stream_reader, parsed_header);
    defer std.testing.allocator.free(frame_infos);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var out_writer = out.writer(std.testing.allocator);
    try writeInfo(&out_writer, parsed_header, frame_infos);

    try std.testing.expectEqualStrings(
        "Header:\n" ++
            "  size: 2x3\n" ++
            "  fps: 30/1\n" ++
            "  colorspace: srgb\n" ++
            "  channels: rgba\n" ++
            "  flags: rgb_only=false, frame_metadata=true\n" ++
            "  gop_size: 4\n" ++
            "  has_audio: false\n" ++
            "  audio_sample_rate: 0\n" ++
            "  audio_channels: 0\n" ++
            "  frame_count: 2\n" ++
            "Frames:\n" ++
            "  count: 2\n" ++
            "  [0] type=iframe payload_bytes=2 duration_us=10\n" ++
            "  [1] type=pframe payload_bytes=3 duration_us=20\n",
        out.items,
    );
}

test "cli info output notes disabled frame metadata" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const header = qov.Header{
        .width = 2,
        .height = 3,
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 4,
        .has_audio = false,
        .audio_sample_rate = 0,
        .audio_channels = 0,
        .audio_frames_per_chunk = 0,
        .frame_count = 1,
    };

    var writer = buffer.writer(std.testing.allocator);
    try qov.writeHeader(&writer, header);
    try qov.writeChunkHeader(&writer, .{
        .chunk_type = .iframe,
        .payload_size = 2,
        .frame_duration_us = 0,
    }, false);
    try writer.writeAll(&[_]u8{ 0x01, 0x02 });

    var stream = std.io.fixedBufferStream(buffer.items);
    var stream_reader = stream.reader();
    const parsed_header = try qov.readHeader(&stream_reader);
    const frame_infos = try collectFrameMetadata(std.testing.allocator, &stream_reader, parsed_header);
    defer std.testing.allocator.free(frame_infos);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var out_writer = out.writer(std.testing.allocator);
    try writeInfo(&out_writer, parsed_header, frame_infos);

    try std.testing.expectEqualStrings(
        "Header:\n" ++
            "  size: 2x3\n" ++
            "  fps: 30/1\n" ++
            "  colorspace: srgb\n" ++
            "  channels: rgba\n" ++
            "  flags: rgb_only=false, frame_metadata=false\n" ++
            "  gop_size: 4\n" ++
            "  has_audio: false\n" ++
            "  audio_sample_rate: 0\n" ++
            "  audio_channels: 0\n" ++
            "  frame_count: 1\n" ++
            "Frames:\n" ++
            "  count: 1\n" ++
            "  frame_duration_us: disabled\n" ++
            "  [0] type=iframe payload_bytes=2\n",
        out.items,
    );
}
