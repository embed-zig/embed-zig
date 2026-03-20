const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed = b.addModule("embed", .{
        .root_source_file = b.path("lib/embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    const net = b.addModule("net", .{
        .root_source_file = b.path("lib/net.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");
    inline for (.{ embed, net }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
