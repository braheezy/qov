const std = @import("std");
const qov = @import("qov");
const zmpeg = @import("zmpeg");

const ConverterError = error{
    InvalidArgs,
    NoVideo,
    NoAudio,
    EncodeFailed,
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    runMain(allocator) catch |err| {
        if (err == ConverterError.InvalidArgs) {
            std.process.exit(1);
        }
        printStderr("error: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
}

fn runMain(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        try printUsage();
        return ConverterError.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];

    try printStderr("mpeg2qov: {s} -> {s}\n", .{ input_path, output_path });

    try convert(allocator, input_path, output_path);
}

fn printUsage() !void {
    try printStderr(
        "Usage:\n" ++
            "  mpeg2qov <input.mpg> <output.qov>\n" ++
            "\n" ++
            "Converts MPEG-1 video to QOV format.\n",
        .{},
    );
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(fmt, args);
}

fn convert(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    // Open MPEG file
    const mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    const width: u32 = @intCast(mpeg.getWidth());
    const height: u32 = @intCast(mpeg.getHeight());
    if (width == 0 or height == 0) return ConverterError.NoVideo;

    try printStderr("  video: {d}x{d}\n", .{ width, height });

    // Collect all frames and audio
    var frames = std.ArrayList([]u8).empty;
    defer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }

    var audio_samples = std.ArrayList(i16).empty;
    defer audio_samples.deinit(allocator);

    var audio_sample_rate: u32 = 44100;
    var audio_channels: u8 = 2;

    // Decode all content
    _ = mpeg.video_decoder orelse return ConverterError.NoVideo;
    const has_audio = mpeg.audio_decoder != null;

    if (has_audio) {
        try printStderr("  audio: present\n", .{});
    }

    var player = zmpeg.Player.init(mpeg);

    // Set up callbacks to collect frames and audio
    const CollectorCtx = struct {
        frames: *std.ArrayList([]u8),
        audio_samples: *std.ArrayList(i16),
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        frame_count: usize,
        audio_count: usize,
    };

    var ctx = CollectorCtx{
        .frames = &frames,
        .audio_samples = &audio_samples,
        .allocator = allocator,
        .width = width,
        .height = height,
        .frame_count = 0,
        .audio_count = 0,
    };

    player.setVideoCallback(struct {
        fn callback(p: *zmpeg.Player, frame: *const zmpeg.Frame, userdata: ?*anyopaque) void {
            _ = p;
            const c: *CollectorCtx = @ptrCast(@alignCast(userdata));

            const out_w = c.width;
            const out_h = c.height;

            const rgba_size = out_w * out_h * 4;
            const rgba = c.allocator.alloc(u8, rgba_size) catch return;

            yuvToRgba(
                rgba,
                frame.y.data,
                frame.cb.data,
                frame.cr.data,
                out_w,
                out_h,
                frame.y.width,
                frame.cb.width,
            );

            c.frames.append(c.allocator, rgba) catch {
                c.allocator.free(rgba);
                return;
            };
            c.frame_count += 1;
        }
    }.callback, &ctx);

    if (has_audio) {
        player.setAudioCallback(struct {
            fn callback(p: *zmpeg.Player, samples: *const zmpeg.Samples, userdata: ?*anyopaque) void {
                _ = p;
                const c: *CollectorCtx = @ptrCast(@alignCast(userdata));

                // Convert f32 interleaved to i16 interleaved
                const count = samples.count * 2; // stereo
                for (0..count) |i| {
                    const f = samples.interleaved[i];
                    const scaled = f * 32767.0;
                    const clamped = @max(-32768.0, @min(32767.0, scaled));
                    const sample: i16 = @intFromFloat(clamped);
                    c.audio_samples.append(c.allocator, sample) catch return;
                }
                c.audio_count += samples.count;
            }
        }.callback, &ctx);
    }

    // Decode everything - use large time chunks for batch processing
    // Stop when demux is done and no more frames/audio are being produced
    var max_iterations: usize = 100000; // Safety limit
    while (max_iterations > 0) : (max_iterations -= 1) {
        const prev_frames = ctx.frame_count;
        const prev_audio = ctx.audio_count;

        try player.decode(1.0, 0);

        // Check if we're done: demux finished and no new content produced
        if (player.demux_done and ctx.frame_count == prev_frames and ctx.audio_count == prev_audio) {
            break;
        }

        // Progress indicator every 100 frames
        if (ctx.frame_count > 0 and ctx.frame_count % 100 == 0 and ctx.frame_count != prev_frames) {
            try printStderr("  progress: {d} frames...\n", .{ctx.frame_count});
        }
    }

    try printStderr("  decoded {d} video frames, {d} audio samples\n", .{ ctx.frame_count, ctx.audio_count });

    if (frames.items.len == 0) return ConverterError.NoVideo;

    // Encode audio to QOA if present
    var audio_chunks: ?[]const []const u8 = null;
    var audio_chunks_storage = std.ArrayList([]u8).empty;
    defer {
        for (audio_chunks_storage.items) |chunk| allocator.free(chunk);
        audio_chunks_storage.deinit(allocator);
    }

    if (has_audio and audio_samples.items.len > 0) {
        audio_sample_rate = 44100; // MPEG-1 audio typical
        audio_channels = 2;

        // Encode audio to QOA frames
        const samples_per_qoa_frame = 256 * 20; // QOA: 256 slices * 20 samples
        const total_samples = audio_samples.items.len / 2; // stereo pairs
        var sample_offset: usize = 0;

        while (sample_offset < total_samples) {
            const remaining = total_samples - sample_offset;
            const frame_samples = @min(remaining, samples_per_qoa_frame);

            var qoa_frame = std.ArrayList(u8).empty;
            defer qoa_frame.deinit(allocator);

            try encodeQoaFrame(allocator, &qoa_frame, audio_samples.items, sample_offset, frame_samples, audio_channels, audio_sample_rate);

            const chunk = try allocator.dupe(u8, qoa_frame.items);
            try audio_chunks_storage.append(allocator, chunk);

            sample_offset += frame_samples;
        }

        // Convert to slice of slices for QOV
        const chunks_slice = try allocator.alloc([]const u8, audio_chunks_storage.items.len);
        for (audio_chunks_storage.items, 0..) |chunk, i| {
            chunks_slice[i] = chunk;
        }
        audio_chunks = chunks_slice;

        try printStderr("  encoded {d} QOA frames\n", .{audio_chunks_storage.items.len});
    }
    defer if (audio_chunks) |c| allocator.free(c);

    // Build QOV header
    const header = qov.Header{
        .width = @intCast(width),
        .height = @intCast(height),
        .fps_num = 30,
        .fps_den = 1,
        .colorspace = .srgb,
        .channels = .rgba,
        .gop_size = 30,
        .has_audio = audio_chunks != null,
        .audio_sample_rate = if (audio_chunks != null) audio_sample_rate else 0,
        .audio_channels = if (audio_chunks != null) audio_channels else 0,
        .audio_frames_per_chunk = if (audio_chunks != null) 1 else 0,
        .frame_count = @intCast(frames.items.len),
    };

    // Write output
    var out_file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);

    // Convert frames list to slice of const slices
    var frame_slices = try allocator.alloc([]const u8, frames.items.len);
    defer allocator.free(frame_slices);
    for (frames.items, 0..) |frame, i| {
        frame_slices[i] = frame;
    }

    try qov.encodeStreamWithOptions(allocator, &out_writer.interface, header, frame_slices, null, .{
        .audio_chunks = audio_chunks,
    });
    try out_writer.interface.flush();

    try printStderr("  wrote {s}\n", .{output_path});
}

// YUV to RGBA conversion (BT.601 full range)
// Uses actual plane strides which may differ from output dimensions due to macroblock alignment
fn yuvToRgba(rgba: []u8, y_plane: []const u8, cb_plane: []const u8, cr_plane: []const u8, width: u32, height: u32, y_stride: u32, chroma_stride: u32) void {
    for (0..height) |row| {
        for (0..width) |col| {
            // Use actual plane strides for indexing
            const y_idx = row * y_stride + col;
            const chroma_idx = (row / 2) * chroma_stride + (col / 2);

            // YCbCr to RGB (BT.601)
            // Standard formula:
            // R = 1.164(Y-16) + 1.596(Cr-128)
            // G = 1.164(Y-16) - 0.392(Cb-128) - 0.813(Cr-128)
            // B = 1.164(Y-16) + 2.017(Cb-128)
            //
            // Using fixed point with <<8 multiplier:
            // 1.164 * 256 = 298
            // 1.596 * 256 = 409
            // 0.392 * 256 = 100
            // 0.813 * 256 = 208
            // 2.017 * 256 = 516

            const y: i32 = @intCast(y_plane[y_idx]);
            const cb: i32 = @intCast(cb_plane[chroma_idx]);
            const cr: i32 = @intCast(cr_plane[chroma_idx]);

            // Compute with proper BT.601 conversion
            const c: i32 = y - 16;
            const d: i32 = cb - 128;
            const e: i32 = cr - 128;

            var r: i32 = (298 * c + 409 * e + 128) >> 8;
            var g: i32 = (298 * c - 100 * d - 208 * e + 128) >> 8;
            var b: i32 = (298 * c + 516 * d + 128) >> 8;

            r = @max(0, @min(255, r));
            g = @max(0, @min(255, g));
            b = @max(0, @min(255, b));

            // Output uses actual width for RGBA layout
            const rgba_idx = (row * width + col) * 4;
            rgba[rgba_idx] = @intCast(r);
            rgba[rgba_idx + 1] = @intCast(g);
            rgba[rgba_idx + 2] = @intCast(b);
            rgba[rgba_idx + 3] = 255;
        }
    }
}

// QOA Encoder constants
const qoa_slice_len = 20;
const qoa_slices_per_frame = 256;
const qoa_frame_len = qoa_slices_per_frame * qoa_slice_len;
const qoa_lms_len = 4;

const qoa_quant_table = [17]i32{
    7, 7, 7, 5, 5, 3, 3, 1,
    0,
    0, 2, 2, 4, 4, 6, 6, 6,
};

const qoa_scalefactor_table = [16]i32{
    1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048,
};

const qoa_reciprocal_table = [16]i32{
    65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32,
};

const qoa_dequant_table = [16][8]i16{
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

const QoaLms = struct {
    history: [qoa_lms_len]i32,
    weights: [qoa_lms_len]i32,

    fn init() QoaLms {
        return .{
            .history = .{ 0, 0, 0, 0 },
            .weights = .{ 0, 0, -(1 << 13), 1 << 14 },
        };
    }

    fn predict(self: *QoaLms) i32 {
        var prediction: i32 = 0;
        for (0..qoa_lms_len) |i| {
            prediction +%= self.weights[i] *% self.history[i];
        }
        return prediction >> 13;
    }

    fn update(self: *QoaLms, sample: i16, residual: i16) void {
        const delta: i32 = @as(i32, residual) >> 4;
        for (0..qoa_lms_len) |i| {
            self.weights[i] += if (self.history[i] < 0) -delta else delta;
        }
        for (0..qoa_lms_len - 1) |i| {
            self.history[i] = self.history[i + 1];
        }
        self.history[qoa_lms_len - 1] = @intCast(sample);
    }
};

fn qoaDiv(v: i32, scalefactor: usize) i32 {
    const reciprocal: i64 = qoa_reciprocal_table[scalefactor];
    const n: i32 = @intCast((@as(i64, v) * reciprocal + (1 << 15)) >> 16);
    const sgn_v: i32 = @as(i32, @intFromBool(v > 0)) - @as(i32, @intFromBool(v < 0));
    const sgn_n: i32 = @as(i32, @intFromBool(n > 0)) - @as(i32, @intFromBool(n < 0));
    return n + sgn_v - sgn_n;
}

fn qoaClampS16(v: i32) i16 {
    if (v <= -32768) return -32768;
    if (v >= 32767) return 32767;
    return @truncate(v);
}

fn encodeQoaFrame(allocator: std.mem.Allocator, out: *std.ArrayList(u8), samples: []const i16, sample_offset: usize, frame_samples: usize, channels: u8, sample_rate: u32) !void {
    const slices = (frame_samples + qoa_slice_len - 1) / qoa_slice_len;
    const frame_size = 8 + (qoa_lms_len * 4 * channels) + (8 * slices * channels);

    // Frame header
    var fh: u64 = 0;
    fh |= (@as(u64, channels) & 0xff) << 56;
    fh |= (@as(u64, sample_rate) & 0x00ff_ffff) << 32;
    fh |= (@as(u64, frame_samples) & 0x0000_ffff) << 16;
    fh |= (@as(u64, frame_size) & 0x0000_ffff);
    try writeU64BE(allocator, out, fh);

    // Initialize LMS per channel
    var lms: [8]QoaLms = undefined;
    for (0..channels) |c| {
        lms[c] = QoaLms.init();
    }

    // Write LMS state (initial zeros)
    for (0..channels) |_| {
        try writeU64BE(allocator, out, 0); // history
        try writeU64BE(allocator, out, 0x0000_0000_e000_4000); // weights: 0, 0, -8192, 16384
    }

    // Encode slices
    var prev_scalefactor: [8]usize = .{0} ** 8;
    var sample_idx: usize = 0;

    while (sample_idx < frame_samples) : (sample_idx += qoa_slice_len) {
        for (0..channels) |c| {
            const slice_samples = @min(qoa_slice_len, frame_samples - sample_idx);

            var best_rank: u64 = std.math.maxInt(u64);
            var best_slice: u64 = 0;
            var best_lms = lms[c];
            var best_sf: usize = 0;

            // Try all scalefactors
            for (0..16) |sfi| {
                const sf = (sfi + prev_scalefactor[c]) & 15;
                var state = lms[c];
                var slice_bits: u64 = @as(u64, sf);
                var rank: u64 = 0;

                for (0..slice_samples) |k| {
                    const abs_idx = (sample_offset + sample_idx + k) * channels + c;
                    if (abs_idx >= samples.len) break;

                    const sample: i32 = samples[abs_idx];
                    const predicted = state.predict();
                    const residual = sample - predicted;
                    const scaled = qoaDiv(residual, sf);
                    const clamped = std.math.clamp(scaled, -8, 8);
                    const quantized: usize = @intCast(qoa_quant_table[@intCast(clamped + 8)]);
                    const dequantized: i32 = qoa_dequant_table[sf][quantized];
                    const reconstructed = qoaClampS16(predicted + dequantized);

                    const err: i64 = @as(i64, sample) - @as(i64, reconstructed);
                    rank += @intCast(err * err);
                    if (rank > best_rank) break;

                    state.update(reconstructed, @truncate(dequantized));
                    slice_bits = (slice_bits << 3) | @as(u64, quantized);
                }

                if (rank < best_rank) {
                    best_rank = rank;
                    best_slice = slice_bits;
                    best_lms = state;
                    best_sf = sf;
                }
            }

            prev_scalefactor[c] = best_sf;
            lms[c] = best_lms;

            // Pad if needed
            if (slice_samples < qoa_slice_len) {
                const pad = qoa_slice_len - slice_samples;
                best_slice <<= @intCast(pad * 3);
            }

            try writeU64BE(allocator, out, best_slice);
        }
    }
}

fn writeU64BE(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    try out.appendSlice(allocator, &bytes);
}
