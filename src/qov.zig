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
