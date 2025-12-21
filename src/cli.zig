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
    UnsupportedQoi,
    FrameSizeMismatch,
    InvalidQov,
    StreamingNotSupported,
};

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
        try runEncode(allocator, args[2], args[3..]);
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len != 4) {
            try printUsage();
            return CliError.InvalidArgs;
        }
        try runDecode(allocator, args[2], args[3]);
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
            "  qov encode <output.qov> <input1.qoi> [input2.qoi ...]\n" ++
            "  qov decode <input.qov> <output_dir>\n",
        .{},
    );
}

fn isReportedError(err: anyerror) bool {
    return err == CliError.InvalidArgs or
        err == CliError.InvalidQoi or
        err == CliError.UnsupportedQoi or
        err == CliError.FrameSizeMismatch;
}

fn runEncode(allocator: std.mem.Allocator, output_path: []const u8, input_paths: []const []const u8) !void {
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
        .frame_count = @intCast(frames.items.len),
    };

    var out_file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [8192]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    try qov.encodeStream(allocator, &out_writer.interface, header, frames.items, null);
    try out_writer.interface.flush();
}

fn runDecode(allocator: std.mem.Allocator, input_path: []const u8, output_dir: []const u8) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(usize));
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    var stream_reader = stream.reader();
    const header = try qov.readHeader(&stream_reader);

    if (header.frame_count == 0) return CliError.StreamingNotSupported;

    const frame_count: usize = @intCast(header.frame_count);
    const frame_bytes = qov.headerFrameBytes(header);

    const frames = try allocator.alloc([]u8, frame_count);
    defer {
        for (frames) |frame| allocator.free(frame);
        allocator.free(frames);
    }

    for (frames) |*frame| {
        frame.* = try allocator.alloc(u8, frame_bytes);
    }

    stream.pos = 0;
    stream_reader = stream.reader();
    _ = try qov.decodeStream(allocator, &stream_reader, frames);

    try std.fs.cwd().makePath(output_dir);

    const rgb_only = qov.isRgbOnly(header);
    var rgba_frame: ?[]u8 = null;
    defer if (rgba_frame) |buffer| allocator.free(buffer);
    if (rgb_only) {
        const rgba_bytes = @as(usize, header.width) * @as(usize, header.height) * 4;
        rgba_frame = try allocator.alloc(u8, rgba_bytes);
    }

    for (frames, 0..) |frame, index| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/frame_{d:0>6}.qoi", .{ output_dir, index });
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
    }
}

fn reportInvalidQoi(path: []const u8, err: anyerror) !void {
    const reason = describeQoiError(err);
    try printStderr("error: invalid QOI input '{s}': {s}\n", .{ path, reason });
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
