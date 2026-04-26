const std = @import("std");
const sdl = @import("sdl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("qov", .{
        .root_source_file = b.path("src/qov.zig"),
        .target = target,
    });

    const sdl_sdk = sdl.init(b, .{});

    const exe = b.addExecutable(.{
        .name = "qov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qov", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const player_module = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
        .target = target,
        .optimize = optimize,
    });
    player_module.addImport("qov", mod);
    player_module.addImport("sdl2", sdl_sdk.getWrapperModule());

    const player_exe = b.addExecutable(.{
        .name = "qov-play",
        .root_module = player_module,
    });
    sdl_sdk.link(b.graph.io, player_exe, .static, sdl.Library.SDL2);
    b.installArtifact(player_exe);

    // "play" step - run qov-play directly with a .qov file
    const play_step = b.step("play", "Play a QOV file: zig build play -- <file.qov>");
    const play_cmd = b.addRunArtifact(player_exe);
    play_step.dependOn(&play_cmd.step);
    play_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        play_cmd.addArgs(args);
    }

    // MPEG to QOV converter
    const zmpeg_dep = b.dependency("zmpeg", .{
        .target = target,
    });
    const zmpeg_mod = zmpeg_dep.module("zmpeg");

    const converter_module = b.createModule(.{
        .root_source_file = b.path("src/mpeg2qov.zig"),
        .target = target,
        .optimize = optimize,
    });
    converter_module.addImport("qov", mod);
    converter_module.addImport("zmpeg", zmpeg_mod);

    const converter_exe = b.addExecutable(.{
        .name = "mpeg2qov",
        .root_module = converter_module,
    });
    b.installArtifact(converter_exe);

    const convert_step = b.step("convert", "Convert MPEG to QOV: zig build convert -- <input.mpg> <output.qov>");
    const convert_cmd = b.addRunArtifact(converter_exe);
    convert_step.dependOn(&convert_cmd.step);
    convert_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        convert_cmd.addArgs(args);
    }

    // "run" step - convert MPEG and play it: zig build run -- <input.mpg>
    const run_step = b.step("run", "Convert MPEG and play: zig build run -- <input.mpg>");
    if (b.args) |args| {
        if (args.len >= 1) {
            const input_file = args[0];
            const temp_qov = "/tmp/zig_build_run.qov";

            // Step 1: Run mpeg2qov to convert
            const convert_run = b.addRunArtifact(converter_exe);
            convert_run.step.dependOn(b.getInstallStep());
            convert_run.addArg(input_file);
            convert_run.addArg(temp_qov);

            // Step 2: Run qov-play on the converted file
            const play_run = b.addRunArtifact(player_exe);
            play_run.step.dependOn(&convert_run.step);
            play_run.addArg(temp_qov);
            // Pass remaining args (like --loop) to player
            for (args[1..]) |arg| {
                play_run.addArg(arg);
            }

            run_step.dependOn(&play_run.step);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
