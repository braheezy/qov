const std = @import("std");
const qov = @import("qov.zig");

const qoi_magic = [4]u8{ 'q', 'o', 'i', 'f' };

const QoiHeader = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const output_dir = if (args.len > 1) args[1] else "testdata/qoi_anim";
    const frame_count: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 48;
    const width: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 96;
    const height: usize = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 64;

    try std.Io.Dir.cwd().createDirPath(io, output_dir);

    const pixel_bytes = width * height * 4;
    const pixels = try allocator.alloc(u8, pixel_bytes);
    defer allocator.free(pixels);

    const square_size: usize = 16;

    for (0..frame_count) |frame_index| {
        drawFrame(pixels, width, height, frame_index, square_size);

        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}/frame_{d:0>6}.qoi",
            .{ output_dir, frame_index },
        );
        defer allocator.free(filename);

        var file = try std.Io.Dir.cwd().createFile(io, filename, .{ .truncate = true });
        defer file.close(io);

        var buf: [8192]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writeQoi(&writer.interface, @intCast(width), @intCast(height), pixels);
        try writer.interface.flush();
    }
}

fn drawFrame(pixels: []u8, width: usize, height: usize, frame_index: usize, square_size: usize) void {
    const base_r: u8 = 16;
    const base_g: u8 = 18;
    const base_b: u8 = 24;

    const max_x = if (width > square_size) width - square_size else 0;
    const max_y = if (height > square_size) height - square_size else 0;
    const x0 = if (max_x > 0) (frame_index * 3) % max_x else 0;
    const y0 = if (max_y > 0) (frame_index * 2) % max_y else 0;

    const x1 = if (max_x > 0) (max_x - (frame_index * 4) % max_x) else 0;
    const y1 = if (max_y > 0) (max_y - (frame_index * 3) % max_y) else 0;

    const square_r: u8 = @intCast(80 + (frame_index * 7) % 160);
    const square_g: u8 = @intCast(40 + (frame_index * 5) % 200);
    const square_b: u8 = @intCast(200 - (frame_index * 3) % 160);

    const square2_r: u8 = @intCast(200 - (frame_index * 6) % 180);
    const square2_g: u8 = @intCast(60 + (frame_index * 9) % 160);
    const square2_b: u8 = @intCast(50 + (frame_index * 4) % 180);

    var idx: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            var r = base_r;
            var g = base_g;
            var b = base_b;

            if (x >= x0 and x < x0 + square_size and y >= y0 and y < y0 + square_size) {
                r = square_r;
                g = square_g;
                b = square_b;
            } else if (x >= x1 and x < x1 + square_size and y >= y1 and y < y1 + square_size) {
                r = square2_r;
                g = square2_g;
                b = square2_b;
            }

            pixels[idx] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = 0xFF;
            idx += 4;
        }
    }
}

fn writeQoi(writer: anytype, width: u32, height: u32, pixels: []const u8) !void {
    if (pixels.len % 4 != 0) return error.InvalidPixels;

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
