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
    InvalidQov,
    StreamingNotSupported,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

fn printUsage() !void {
    const err = std.io.getStdErr().writer();
    try err.writeAll(
        "Usage:\n" ++
            "  qov encode <output.qov> <input1.qoi> [input2.qoi ...]\n" ++
            "  qov decode <input.qov> <output_dir>\n",
    );
}

fn runEncode(allocator: std.mem.Allocator, output_path: []const u8, input_paths: []const []const u8) !void {
    var frames = std.ArrayList([]u8).empty;
    defer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }

    var width: u32 = 0;
    var height: u32 = 0;

    for (input_paths) |path| {
        const file_bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(file_bytes);

        const decoded = try decodeQoiToRgba(allocator, file_bytes);
        errdefer allocator.free(decoded.pixels);

        if (width == 0 and height == 0) {
            width = decoded.header.width;
            height = decoded.header.height;
        } else if (decoded.header.width != width or decoded.header.height != height) {
            allocator.free(decoded.pixels);
            return CliError.InvalidQoi;
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

    try qov.encodeStream(allocator, out_file.writer(), header, frames.items);
}

fn runDecode(allocator: std.mem.Allocator, input_path: []const u8, output_dir: []const u8) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(usize));
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    const header = try qov.readHeader(stream.reader());

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
    _ = try qov.decodeStream(allocator, stream.reader(), frames);

    try std.fs.cwd().makePath(output_dir);

    for (frames, 0..) |frame, index| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/frame_{d:0>6}.qoi", .{ output_dir, index });
        defer allocator.free(filename);

        var out_file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
        defer out_file.close();

        try writeQoi(out_file.writer(), header.width, header.height, frame);
    }
}

fn decodeQoiToRgba(allocator: std.mem.Allocator, file_bytes: []const u8) !struct { header: QoiHeader, pixels: []u8 } {
    var stream = std.io.fixedBufferStream(file_bytes);
    const header = try readQoiHeader(stream.reader());

    if (header.channels != 3 and header.channels != 4) return CliError.UnsupportedQoi;
    if (header.width == 0 or header.height == 0) return CliError.InvalidQoi;

    const pixel_count = try std.math.mul(usize, @intCast(header.width), @intCast(header.height));
    const pixel_bytes = try std.math.mul(usize, pixel_count, 4);

    const pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);

    try qov.decodeIFrame(stream.reader(), pixels);

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

    try writeQoi(buffer.writer(allocator), 2, 1, &pixels);

    const decoded = try decodeQoiToRgba(allocator, buffer.items);
    defer allocator.free(decoded.pixels);

    try std.testing.expectEqual(@as(u32, 2), decoded.header.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.header.height);
    try std.testing.expectEqual(@as(u8, 4), decoded.header.channels);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}
