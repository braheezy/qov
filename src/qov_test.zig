const std = @import("std");
const qov = @import("qov.zig");

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
    const header = try readQoiHeader(stream.reader());

    if (header.channels != 4) return QoiError.InvalidQoi;
    if (header.width == 0 or header.height == 0) return QoiError.InvalidQoi;

    const pixel_count = std.math.mul(usize, @intCast(header.width), @intCast(header.height)) catch return QoiError.InvalidQoi;
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch return QoiError.InvalidQoi;

    const pixels = try allocator.alloc(u8, pixel_bytes);
    errdefer allocator.free(pixels);

    try qov.decodeIFrame(stream.reader(), pixels);

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
        .frame_count = @intCast(frames.items.len),
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);

    try qov.encodeStream(allocator, encoded.writer(allocator), header, frames.items);

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
    const decoded_header = try qov.decodeStream(allocator, stream.reader(), out_frames);

    try std.testing.expectEqual(header.width, decoded_header.width);
    try std.testing.expectEqual(header.height, decoded_header.height);
    try std.testing.expectEqual(header.frame_count, decoded_header.frame_count);

    for (frames.items, 0..) |frame, index| {
        try std.testing.expectEqualSlices(u8, frame, out_frames[index]);
    }

    try std.testing.expectEqual(encoded.items.len, stream.pos);
}
