const std = @import("std");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const embed_mod = b.modules.get("embed").?;

    const bleterm_exe = b.addExecutable(.{
        .name = "bleterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bin/bleterm/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "embed", .module = embed_mod }},
        }),
    });

    if (target.result.os.tag == .macos) {
        bleterm_exe.linkFramework("CoreBluetooth");
        bleterm_exe.linkFramework("Foundation");
    }

    const run_bleterm = b.addRunArtifact(bleterm_exe);
    if (b.args) |args| run_bleterm.addArgs(args);

    b.step("run-bleterm", "Run bleterm CLI").dependOn(&run_bleterm.step);
    b.step("build-bleterm", "Build bleterm CLI").dependOn(&bleterm_exe.step);
}
