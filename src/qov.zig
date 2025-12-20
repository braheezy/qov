const std = @import("std");

pub const magic = [4]u8{ 'q', 'o', 'v', 'f' };
pub const version: u8 = 1;

pub const header_size: usize = 32;
pub const chunk_header_size: usize = 5;
pub const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const ChunkType = enum(u8) {
    iframe = 0,
    pframe = 1,
    audio = 2,
};

pub const Header = struct {
    width: u16,
    height: u16,
    fps_num: u16,
    fps_den: u16,
    colorspace: Colorspace,
    channels: Channels,
    gop_size: u8,
    has_audio: bool,
    audio_sample_rate: u32,
    audio_channels: u8,
    frame_count: u32,
};

pub const ChunkHeader = struct {
    chunk_type: ChunkType,
    payload_size: u32,
};

pub const QovError = error{
    InvalidMagic,
    UnsupportedVersion,
    UnsupportedChannels,
    UnsupportedColorspace,
    UnsupportedAudio,
    InvalidHeader,
    InvalidChunk,
    UnexpectedEof,
};

pub fn hasAudio(header: Header) bool {
    return header.has_audio;
}

pub fn isRgba(header: Header) bool {
    return header.channels == .rgba;
}

pub fn headerFramePixels(header: Header) usize {
    return @as(usize, header.width) * @as(usize, header.height);
}

pub fn headerFrameBytes(header: Header) usize {
    return headerFramePixels(header) * 4;
}

pub fn validateHeader(header: Header) QovError!void {
    if (header.channels != .rgba) return QovError.UnsupportedChannels;
    if (header.has_audio) return QovError.UnsupportedAudio;
    if (header.fps_den == 0) return QovError.InvalidHeader;
    if (header.width == 0 or header.height == 0) return QovError.InvalidHeader;
}

pub fn chunkTypeFromByte(byte: u8) QovError!ChunkType {
    return switch (byte) {
        0 => .iframe,
        1 => .pframe,
        2 => .audio,
        else => QovError.InvalidChunk,
    };
}

pub fn colorspaceFromByte(byte: u8) QovError!Colorspace {
    return switch (byte) {
        0 => .srgb,
        1 => .linear,
        else => QovError.UnsupportedColorspace,
    };
}

pub fn channelsFromByte(byte: u8) QovError!Channels {
    return switch (byte) {
        3 => .rgb,
        4 => .rgba,
        else => QovError.UnsupportedChannels,
    };
}

pub fn channelByte(channels: Channels) u8 {
    return @intFromEnum(channels);
}

pub fn colorspaceByte(colorspace: Colorspace) u8 {
    return @intFromEnum(colorspace);
}

pub fn chunkTypeByte(chunk_type: ChunkType) u8 {
    return @intFromEnum(chunk_type);
}

fn readExact(reader: anytype, buf: []u8) (QovError || @TypeOf(reader).Error)!void {
    const amount = try reader.readAll(buf);
    if (amount != buf.len) return QovError.UnexpectedEof;
}

fn readByteExact(reader: anytype) (QovError || @TypeOf(reader).Error)!u8 {
    var buf: [1]u8 = undefined;
    try readExact(reader, &buf);
    return buf[0];
}

pub fn readHeader(reader: anytype) (QovError || @TypeOf(reader).Error)!Header {
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
        .gop_size = buf[15],
        .has_audio = switch (buf[16]) {
            0 => false,
            1 => true,
            else => return QovError.InvalidHeader,
        },
        .audio_sample_rate = (@as(u32, buf[17]) << 16) | (@as(u32, buf[18]) << 8) | @as(u32, buf[19]),
        .audio_channels = buf[20],
        .frame_count = std.mem.readInt(u32, buf[21..25], .big),
    };

    try validateHeader(header);

    return header;
}

pub fn writeHeader(writer: anytype, header: Header) (QovError || @TypeOf(writer).Error)!void {
    try validateHeader(header);
    if (header.audio_sample_rate > 0xFFFFFF) return QovError.InvalidHeader;

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

    try writer.writeAll(&buf);
}

pub fn readChunkHeader(reader: anytype) (QovError || @TypeOf(reader).Error)!ChunkHeader {
    var buf: [chunk_header_size]u8 = undefined;
    try readExact(reader, &buf);

    return ChunkHeader{
        .chunk_type = try chunkTypeFromByte(buf[0]),
        .payload_size = std.mem.readInt(u32, buf[1..5], .big),
    };
}

pub fn writeChunkHeader(writer: anytype, header: ChunkHeader) (QovError || @TypeOf(writer).Error)!void {
    var buf: [chunk_header_size]u8 = undefined;
    buf[0] = chunkTypeByte(header.chunk_type);
    std.mem.writeInt(u32, buf[1..5], header.payload_size, .big);
    try writer.writeAll(&buf);
}

pub fn readChunkPayload(reader: anytype, payload: []u8) (QovError || @TypeOf(reader).Error)!void {
    try readExact(reader, payload);
}

pub fn writeChunkPayload(writer: anytype, payload: []const u8) (QovError || @TypeOf(writer).Error)!void {
    try writer.writeAll(payload);
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

pub fn encodeIFrame(writer: anytype, pixels: []const u8) (QovError || @TypeOf(writer).Error)!void {
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

pub fn decodeIFrame(reader: anytype, pixels: []u8) (QovError || @TypeOf(reader).Error)!void {
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
        .frame_count = 0,
    };

    try validateHeader(header);
    try std.testing.expectEqual(@as(usize, 24), headerFrameBytes(header));
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
        .frame_count = 12,
    };

    var buffer: [header_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try writeHeader(stream.writer(), header);

    stream.pos = 0;
    const decoded = try readHeader(stream.reader());

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
    try std.testing.expectEqual(header.frame_count, decoded.frame_count);
}

test "chunk header and payload read/write roundtrip" {
    const payload = "qov";
    const header = ChunkHeader{
        .chunk_type = .iframe,
        .payload_size = payload.len,
    };

    var buffer: [chunk_header_size + payload.len]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try writeChunkHeader(stream.writer(), header);
    try writeChunkPayload(stream.writer(), payload);

    stream.pos = 0;
    const decoded_header = try readChunkHeader(stream.reader());

    var decoded_payload: [payload.len]u8 = undefined;
    try readChunkPayload(stream.reader(), &decoded_payload);

    try std.testing.expectEqual(header.chunk_type, decoded_header.chunk_type);
    try std.testing.expectEqual(header.payload_size, decoded_header.payload_size);
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

    try encodeIFrame(encoded.writer(std.testing.allocator), &pixels);

    var decoded: [pixels.len]u8 = undefined;
    var stream = std.io.fixedBufferStream(encoded.items);
    try decodeIFrame(stream.reader(), &decoded);

    try std.testing.expectEqualSlices(u8, &pixels, &decoded);
    try std.testing.expectEqual(encoded.items.len, stream.pos);
}
