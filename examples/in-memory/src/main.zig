const std = @import("std");
const qov = @import("qov");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const frame0 = [_]u8{
        0x12, 0x34, 0x56, 0xFF,
        0xAA, 0xBB, 0xCC, 0xFF,
    };
    const frame1 = [_]u8{
        0xDE, 0xAD, 0xBE, 0xEF,
        0x00, 0x11, 0x22, 0xFF,
    };
    const frames = [_][]const u8{ &frame0, &frame1 };

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
        .frame_count = frames.len,
    };

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    var writer = encoded.writer(allocator);
    try qov.encodeStream(allocator, &writer, header, &frames, null);

    var stream = std.io.fixedBufferStream(encoded.items);
    var reader = stream.reader();

    var out0: [frame0.len]u8 = undefined;
    var out1: [frame1.len]u8 = undefined;
    var out_frames = [_][]u8{ &out0, &out1 };
    _ = try qov.decodeStream(allocator, &reader, &out_frames);

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "Decoded first pixel RGBA: {d},{d},{d},{d}\n",
        .{ out0[0], out0[1], out0[2], out0[3] },
    );
}
