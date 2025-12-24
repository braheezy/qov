const std = @import("std");
const qov = @import("qov");
const sdl = @import("sdl2");

const PlayerError = error{
    InvalidArgs,
    InvalidQov,
    AudioDecodeError,
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    runMain(allocator) catch |err| {
        if (err == PlayerError.InvalidArgs) {
            std.process.exit(1);
        }
        if (err == error.SdlError) {
            if (sdl.getError()) |msg| {
                printStderr("sdl error: {s}\n", .{msg}) catch {};
            }
        } else {
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
        return PlayerError.InvalidArgs;
    }

    var input_path: ?[]const u8 = null;
    var loop = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--loop")) {
            loop = true;
            continue;
        }
        if (input_path == null) {
            input_path = arg;
            continue;
        }
        try printUsage();
        return PlayerError.InvalidArgs;
    }

    const path = input_path orelse {
        try printUsage();
        return PlayerError.InvalidArgs;
    };
    try runPlayer(allocator, path, loop);
}

fn printUsage() !void {
    try printStderr(
        "Usage:\n" ++
            "  qov-play [--loop] <input.qov>\n",
        .{},
    );
}

fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&stderr_buf);
    defer err.interface.flush() catch {};
    try err.interface.print(fmt, args);
}

fn runPlayer(allocator: std.mem.Allocator, input_path: []const u8, loop: bool) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(usize));
    defer allocator.free(file_bytes);

    var stream = std.io.fixedBufferStream(file_bytes);
    var reader = stream.reader();
    var decoder = try qov.StreamDecoder(@TypeOf(&reader)).init(allocator, &reader);
    defer decoder.deinit();

    try printStderr(
        "qov-play: {s} ({d}x{d} @ {d}/{d}",
        .{ input_path, decoder.header.width, decoder.header.height, decoder.header.fps_num, decoder.header.fps_den },
    );
    if (decoder.header.has_audio) {
        try printStderr(", audio {d}Hz {d}ch", .{ decoder.header.audio_sample_rate, decoder.header.audio_channels });
    }
    try printStderr(")\n", .{});

    try sdl.init(.{ .video = true, .events = true, .audio = decoder.header.has_audio });
    defer sdl.quit();

    const width: u31 = @intCast(decoder.header.width);
    const height: u31 = @intCast(decoder.header.height);
    const display_width: u31 = @max(width * 4, 320);
    const display_height: u31 = @max(height * 4, 240);

    const window = try sdl.createWindow(
        "QOV Player",
        .centered,
        .centered,
        display_width,
        display_height,
        .{},
    );
    defer window.destroy();

    const renderer = try sdl.createRenderer(window, null, .{
        .accelerated = true,
        .present_vsync = true,
    });
    defer renderer.destroy();
    try renderer.setLogicalSize(@intCast(width), @intCast(height));

    const texture = try sdl.createTexture(
        renderer,
        .rgba8888,
        .streaming,
        width,
        height,
    );
    defer texture.destroy();

    const frame_bytes = qov.headerFrameBytes(decoder.header);
    const rgba_bytes = qov.headerFramePixels(decoder.header) * 4;

    const frame = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(frame);

    var rgba_frame: ?[]u8 = null;
    if (decoder.header.flags.rgb_only) {
        rgba_frame = try allocator.alloc(u8, rgba_bytes);
    }
    defer if (rgba_frame) |buffer| allocator.free(buffer);

    var audio_state: ?AudioState = null;
    if (decoder.header.has_audio) {
        audio_state = try AudioState.init(allocator, decoder.header);
    }
    defer if (audio_state) |*a| a.deinit();

    const default_duration_us = defaultFrameDurationUs(decoder.header);

    var quit = false;
    var had_any_frame = false;
    while (!quit) {
        while (!quit) {
            const packet = try decoder.nextPacket(frame);
            if (packet == null) break;

            switch (packet.?) {
                .audio => |audio_data| {
                    if (audio_state) |*a| {
                        try a.decodeAndQueue(audio_data);
                    }
                },
                .frame => {
                    had_any_frame = true;

                    quit = pollQuit();
                    if (quit) break;

                    const display_frame = if (decoder.header.flags.rgb_only) blk: {
                        const rgba = rgba_frame orelse return PlayerError.InvalidQov;
                        expandRgbToRgba(rgba, frame);
                        break :blk rgba;
                    } else frame;

                    try texture.update(display_frame, decoder.header.width * 4, null);
                    try renderer.clear();
                    try renderer.copy(texture, null, null);
                    renderer.present();

                    const frame_duration_us = if (decoder.header.flags.frame_metadata and decoder.last_frame_duration_us != 0)
                        decoder.last_frame_duration_us
                    else
                        default_duration_us;

                    if (audio_state) |*a| {
                        a.syncDelay(frame_duration_us);
                    } else if (frame_duration_us > 0) {
                        delayFrame(frame_duration_us);
                    }
                },
            }
        }

        if (quit or !loop) break;

        if (audio_state) |*a| {
            a.waitForDrain();
        }

        decoder.deinit();
        stream.reset();
        reader = stream.reader();
        decoder = try qov.StreamDecoder(@TypeOf(&reader)).init(allocator, &reader);
        if (decoder.header.width != @as(u16, @intCast(width)) or decoder.header.height != @as(u16, @intCast(height))) {
            return PlayerError.InvalidQov;
        }
    }

    if (audio_state) |*a| {
        a.waitForDrain();
    }

    holdWindow(renderer, texture, had_any_frame);
}

fn pollQuit() bool {
    while (sdl.pollEvent()) |ev| {
        switch (ev) {
            .quit => return true,
            .key_down => |key| {
                if (key.scancode == .escape) return true;
            },
            else => {},
        }
    }
    return false;
}

fn holdWindow(renderer: sdl.Renderer, texture: sdl.Texture, has_frame: bool) void {
    while (true) {
        if (pollQuit()) break;
        renderer.setColorRGB(0, 0, 0) catch {};
        renderer.clear() catch {};
        if (has_frame) {
            renderer.copy(texture, null, null) catch {};
        }
        renderer.present();
        sdl.delay(16);
    }
}

fn defaultFrameDurationUs(header: qov.Header) u32 {
    if (header.fps_num == 0) return 0;
    const numerator: u64 = 1_000_000 * @as(u64, header.fps_den);
    const denominator: u64 = header.fps_num;
    return @intCast(@min(numerator / denominator, std.math.maxInt(u32)));
}

fn delayFrame(frame_duration_us: u32) void {
    const ms = @max(@as(u32, 1), frame_duration_us / 1000);
    sdl.delay(ms);
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

const AudioState = struct {
    allocator: std.mem.Allocator,
    device: sdl.AudioDevice,
    decoder: qov.QoaFrameDecoder,
    pcm_buffer: []i16,
    sample_rate: u32,
    channels: u8,
    bytes_per_sample: usize,

    fn init(allocator: std.mem.Allocator, header: qov.Header) !AudioState {
        const channels = header.audio_channels;
        const sample_rate = header.audio_sample_rate;

        const max_samples = qov.qoaMaxSamplesPerFrame(channels);
        const pcm_buffer = try allocator.alloc(i16, max_samples);
        errdefer allocator.free(pcm_buffer);

        const audio_result = try sdl.openAudioDevice(.{
            .desired_spec = .{
                .sample_rate = @intCast(sample_rate),
                .buffer_format = sdl.AudioFormat.s16_lsb,
                .channel_count = channels,
                .buffer_size_in_frames = 4096,
                .callback = null,
                .userdata = null,
            },
            .allowed_changes_from_desired = .{},
        });

        audio_result.device.pause(false);

        return .{
            .allocator = allocator,
            .device = audio_result.device,
            .decoder = qov.QoaFrameDecoder.init(channels, sample_rate),
            .pcm_buffer = pcm_buffer,
            .sample_rate = sample_rate,
            .channels = channels,
            .bytes_per_sample = 2 * @as(usize, channels),
        };
    }

    fn deinit(self: *AudioState) void {
        self.device.close();
        self.allocator.free(self.pcm_buffer);
    }

    fn decodeAndQueue(self: *AudioState, audio_data: []const u8) !void {
        var offset: usize = 0;
        while (offset < audio_data.len) {
            const frame_header = try qov.parseQoaFrameHeader(audio_data[offset..]);
            const frame_size: usize = @intCast(frame_header.frame_size);
            if (offset + frame_size > audio_data.len) return PlayerError.AudioDecodeError;

            const result = self.decoder.decodeFrameS16(audio_data[offset .. offset + frame_size], self.pcm_buffer) catch {
                return PlayerError.AudioDecodeError;
            };

            const sample_count = result.frame_length * @as(usize, self.channels);
            const pcm_bytes = std.mem.sliceAsBytes(self.pcm_buffer[0..sample_count]);
            try self.device.queueAudio(pcm_bytes);

            offset += frame_size;
        }
    }

    fn syncDelay(self: *AudioState, frame_duration_us: u32) void {
        const queued_bytes = self.device.getQueuedAudioSize();
        const bytes_per_second = self.sample_rate * self.bytes_per_sample;
        const target_buffer_us: u64 = 100_000;
        const target_buffer_bytes = (target_buffer_us * bytes_per_second) / 1_000_000;

        if (queued_bytes > target_buffer_bytes) {
            const excess_bytes = queued_bytes - target_buffer_bytes;
            const excess_us = (excess_bytes * 1_000_000) / bytes_per_second;
            const delay_us = @min(excess_us, frame_duration_us);
            if (delay_us > 1000) {
                sdl.delay(@intCast(delay_us / 1000));
            }
        }
    }

    fn waitForDrain(self: *AudioState) void {
        while (self.device.getQueuedAudioSize() > 0) {
            if (pollQuit()) break;
            sdl.delay(10);
        }
    }
};
