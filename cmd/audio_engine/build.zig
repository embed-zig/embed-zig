const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_dep = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
        .portaudio = true,
        .speexdsp = true,
    });

    const exe = b.addExecutable(.{
        .name = "audio_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "embed", .module = embed_dep.module("embed") },
            },
        }),
    });
    exe.linkLibrary(embed_dep.artifact("embed_link"));

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);

    b.step("run", "Run audio engine demo").dependOn(&run_exe.step);
    b.step("build-app", "Build audio engine demo").dependOn(&exe.step);
}
