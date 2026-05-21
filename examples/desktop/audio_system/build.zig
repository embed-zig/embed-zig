const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const duration_ms = b.option(u32, "duration-ms", "Playback/record duration in milliseconds") orelse 3000;
    const music = b.option(bool, "music", "Enable generated music tracks") orelse true;
    const gain_db = b.option(i8, "gain-db", "Speaker gain in dB") orelse -6;
    const loopback_gain_db = b.option(i8, "loopback-gain-db", "Mic loopback gain in dB before writing to the mixer track") orelse 9;

    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_stub_mod = b.createModule(.{
        .root_source_file = b.path("src/gstd_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib_dep.module("glib") },
        },
    });

    const audio_system_mod = b.createModule(.{
        .root_source_file = b.path("../../../desktop/lib/device/audio_system.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_stub_mod },
            .{ .name = "portaudio", .module = thirdparty_dep.module("portaudio") },
            .{ .name = "speexdsp", .module = thirdparty_dep.module("speexdsp") },
        },
    });

    const options = b.addOptions();
    options.addOption(u32, "duration_ms", duration_ms);
    options.addOption(bool, "music", music);
    options.addOption(i8, "gain_db", gain_db);
    options.addOption(i8, "loopback_gain_db", loopback_gain_db);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop_audio_system", .module = audio_system_mod },
        },
    });
    exe_mod.addOptions("audio_system_example_config", options);

    const exe = b.addExecutable(.{
        .name = "desktop_audio_system",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the desktop audio system example");
    run_step.dependOn(&run_cmd.step);

    const build_step = b.step("build", "Build the desktop audio system example");
    build_step.dependOn(&exe.step);
    b.default_step = build_step;
}
