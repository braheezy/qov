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
