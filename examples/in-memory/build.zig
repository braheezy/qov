const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qov_module = b.addModule("qov", .{
        .root_source_file = b.path("../../src/qov.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "qov-in-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qov", .module = qov_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the in-memory example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
