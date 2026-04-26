const std = @import("std");

pub const max_channels = 8;

const slice_len = 20;
const slices_per_frame = 256;
const frame_len = slices_per_frame * slice_len;
const lms_len = 4;

const dequant_table = [16][8]i16{
    .{ 1, -1, 3, -3, 5, -5, 7, -7 },
    .{ 5, -5, 18, -18, 32, -32, 49, -49 },
    .{ 16, -16, 53, -53, 95, -95, 147, -147 },
    .{ 34, -34, 113, -113, 203, -203, 315, -315 },
    .{ 63, -63, 210, -210, 378, -378, 588, -588 },
    .{ 104, -104, 345, -345, 621, -621, 966, -966 },
    .{ 158, -158, 528, -528, 950, -950, 1477, -1477 },
    .{ 228, -228, 760, -760, 1368, -1368, 2128, -2128 },
    .{ 316, -316, 1053, -1053, 1895, -1895, 2947, -2947 },
    .{ 422, -422, 1405, -1405, 2529, -2529, 3934, -3934 },
    .{ 548, -548, 1828, -1828, 3290, -3290, 5117, -5117 },
    .{ 696, -696, 2320, -2320, 4176, -4176, 6496, -6496 },
    .{ 868, -868, 2893, -2893, 5207, -5207, 8099, -8099 },
    .{ 1064, -1064, 3548, -3548, 6386, -6386, 9933, -9933 },
    .{ 1286, -1286, 4288, -4288, 7718, -7718, 12005, -12005 },
    .{ 1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336 },
};

pub const Lms = struct {
    history: [lms_len]i32,
    weights: [lms_len]i32,

    fn predict(self: *Lms) i32 {
        var prediction: i32 = 0;
        for (0..lms_len) |i| {
            const mul = @mulWithOverflow(self.weights[i], self.history[i]);
            const sum = @addWithOverflow(prediction, mul[0]);
            prediction = sum[0];
        }
        return prediction >> 13;
    }

    fn update(self: *Lms, sample: i16, residual: i16) void {
        const delta: i32 = @as(i32, residual) >> 4;
        for (0..lms_len) |i| {
            self.weights[i] += if (self.history[i] < 0) -delta else delta;
        }
        for (0..lms_len - 1) |i| {
            self.history[i] = self.history[i + 1];
        }
        self.history[lms_len - 1] = @intCast(sample);
    }
};

fn clamp_s16(v: i32) i16 {
    if (v <= -32768) return -32768;
    if (v >= 32767) return 32767;
    return @truncate(v);
}

pub const FrameHeader = struct {
    channels: u8,
    sample_rate: u32,
    frame_length: u16,
    frame_size: u16,

    pub fn totalSamples(self: FrameHeader) usize {
        return @as(usize, self.frame_length) * @as(usize, self.channels);
    }
};

pub const FrameDecodeResult = struct {
    frame_size: usize,
    frame_length: usize,
};

pub fn parseFrameHeader(bytes: []const u8) !FrameHeader {
    if (bytes.len < 8) return error.FrameHeaderTooSmall;

    const frame_header = std.mem.readInt(u64, bytes[0..8], .big);
    return .{
        .channels = @intCast((frame_header >> 56) & 0x000000FF),
        .sample_rate = @intCast((frame_header >> 32) & 0x00FFFFFF),
        .frame_length = @intCast((frame_header >> 16) & 0x0000FFFF),
        .frame_size = @intCast(frame_header & 0x0000FFFF),
    };
}

pub fn maxFrameBytes(channels: u8) usize {
    return 8 + (lms_len * 4 * @as(usize, channels)) + (8 * slices_per_frame * @as(usize, channels));
}

pub fn maxSamplesPerFrame(channels: u8) usize {
    return frame_len * @as(usize, channels);
}

pub const FrameDecoder = struct {
    channels: u8,
    sample_rate: u32,
    lms: [max_channels]Lms = undefined,

    pub fn init(channels: u8, sample_rate: u32) FrameDecoder {
        return .{ .channels = channels, .sample_rate = sample_rate };
    }

    pub fn decodeFrameS16(self: *FrameDecoder, frame: []const u8, samples: []i16) !FrameDecodeResult {
        const header = try parseFrameHeader(frame);
        if (header.channels == 0 or header.channels > max_channels) return error.InvalidFrameHeader;
        if (header.sample_rate == 0) return error.InvalidFrameHeader;
        if (header.channels != self.channels or header.sample_rate != self.sample_rate) return error.InvalidFrameHeader;

        const channels_usize = @as(usize, header.channels);
        const frame_size = @as(usize, header.frame_size);
        const header_size = 8 + (lms_len * 4 * channels_usize);
        if (frame_size < header_size) return error.FrameTooSmall;
        if (frame_size > frame.len) return error.FrameTooSmall;

        const data_size = frame_size - header_size;
        if (data_size % 8 != 0) return error.InvalidFrameHeader;

        const num_slices = data_size / 8;
        const max_total_samples = num_slices * slices_per_frame;
        const sample_count = @as(usize, header.frame_length);
        if (sample_count * channels_usize > max_total_samples) return error.InvalidFrameHeader;

        const required_samples = sample_count * channels_usize;
        if (samples.len < required_samples) return error.OutputTooSmall;

        var p: usize = 8;

        for (0..channels_usize) |c| {
            const history_ptr = @as(*const [8]u8, @ptrCast(&frame[p]));
            const weights_ptr = @as(*const [8]u8, @ptrCast(&frame[p + 8]));
            var history = std.mem.readInt(u64, history_ptr, .big);
            var weights = std.mem.readInt(u64, weights_ptr, .big);
            p += 16;

            for (0..lms_len) |i| {
                const h_u16: u16 = @truncate(history >> 48);
                const h_i16: i16 = @bitCast(h_u16);
                self.lms[c].history[i] = @intCast(h_i16);
                history <<= 16;
                const w_u16: u16 = @truncate(weights >> 48);
                const w_i16: i16 = @bitCast(w_u16);
                self.lms[c].weights[i] = @intCast(w_i16);
                weights <<= 16;
            }
        }

        var sample_index: usize = 0;
        while (sample_index < sample_count) : (sample_index += slice_len) {
            for (0..channels_usize) |c| {
                const slice_ptr = @as(*const [8]u8, @ptrCast(&frame[p]));
                var slice = std.mem.readInt(u64, slice_ptr, .big);
                p += 8;

                const scalefactor: usize = @intCast((slice >> 60) & 0xF);
                slice <<= 4;
                const slice_start = (sample_index * channels_usize) + c;
                const slice_end = @min(sample_index + slice_len, sample_count) * channels_usize + c;

                var si: usize = slice_start;
                while (si < slice_end) : (si += channels_usize) {
                    const predicted = self.lms[c].predict();
                    const quantized: usize = @intCast((slice >> 61) & 0x7);
                    const dequantized = dequant_table[scalefactor][quantized];
                    const reconstructed = clamp_s16(predicted + @as(i32, dequantized));

                    samples[si] = reconstructed;
                    slice <<= 3;

                    self.lms[c].update(reconstructed, dequantized);
                }
            }
        }

        return .{ .frame_size = frame_size, .frame_length = sample_count };
    }

    pub fn decodeFrameF32(self: *FrameDecoder, frame: []const u8, dst: []f32, scratch: []i16) !FrameDecodeResult {
        const result = try self.decodeFrameS16(frame, scratch);
        const total_samples = result.frame_length * @as(usize, self.channels);
        if (dst.len < total_samples) return error.OutputTooSmall;

        for (scratch[0..total_samples], 0..) |sample, i| {
            dst[i] = @as(f32, @floatFromInt(sample)) / 32768.0;
        }

        return result;
    }
};

test "parse frame header from arcade.qoa" {
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "arcade.qoa", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file_bytes);
    try std.testing.expect(file_bytes.len >= 16);

    const header = try parseFrameHeader(file_bytes[8..16]);
    try std.testing.expectEqual(@as(u8, 2), header.channels);
    try std.testing.expectEqual(@as(u32, 24000), header.sample_rate);
    try std.testing.expectEqual(@as(u16, 5120), header.frame_length);
    try std.testing.expectEqual(@as(u16, 4136), header.frame_size);
}

test "decode first frame to s16 and f32" {
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "arcade.qoa", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file_bytes);
    try std.testing.expect(file_bytes.len >= 16);

    const header = try parseFrameHeader(file_bytes[8..16]);
    const frame_size = @as(usize, header.frame_size);
    var frame_buf = try std.testing.allocator.alloc(u8, frame_size);
    defer std.testing.allocator.free(frame_buf);

    std.mem.copyForwards(u8, frame_buf[0..8], file_bytes[8..16]);
    const payload_len = frame_size - 8;
    @memcpy(frame_buf[8..frame_size], file_bytes[16..][0..payload_len]);

    var decoder = FrameDecoder.init(header.channels, header.sample_rate);
    const total_samples = header.totalSamples();
    const samples_s16 = try std.testing.allocator.alloc(i16, total_samples);
    defer std.testing.allocator.free(samples_s16);

    const result_s16 = try decoder.decodeFrameS16(frame_buf, samples_s16);
    try std.testing.expectEqual(@as(usize, header.frame_size), result_s16.frame_size);
    try std.testing.expectEqual(@as(usize, header.frame_length), result_s16.frame_length);

    var sum_abs: u64 = 0;
    for (samples_s16) |sample| {
        sum_abs += @as(u64, @intCast(@abs(@as(i32, sample))));
    }
    try std.testing.expect(sum_abs != 0);

    const samples_f32 = try std.testing.allocator.alloc(f32, total_samples);
    defer std.testing.allocator.free(samples_f32);
    const scratch = try std.testing.allocator.alloc(i16, total_samples);
    defer std.testing.allocator.free(scratch);

    const result_f32 = try decoder.decodeFrameF32(frame_buf, samples_f32, scratch);
    try std.testing.expectEqual(result_s16.frame_length, result_f32.frame_length);

    for (samples_s16, 0..) |sample, i| {
        const expected = @as(f32, @floatFromInt(sample)) / 32768.0;
        try std.testing.expectApproxEqAbs(expected, samples_f32[i], 1e-6);
    }
}
