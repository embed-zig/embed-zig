const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });

    const server_exe = b.addExecutable(.{
        .name = "netperf-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glib", .module = glib_dep.module("glib") },
                .{ .name = "gstd", .module = gstd_dep.module("gstd") },
                .{ .name = "kcp", .module = thirdparty_dep.module("kcp") },
            },
        }),
    });
    b.installArtifact(server_exe);

    const client_exe = b.addExecutable(.{
        .name = "netperf-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glib", .module = glib_dep.module("glib") },
                .{ .name = "gstd", .module = gstd_dep.module("gstd") },
                .{ .name = "kcp", .module = thirdparty_dep.module("kcp") },
            },
        }),
    });
    b.installArtifact(client_exe);

    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("run-server", "Run the netperf control/data server");
    run_server_step.dependOn(&run_server.step);

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| run_client.addArgs(args);
    const run_client_step = b.step("run-client", "Run the netperf client");
    run_client_step.dependOn(&run_client.step);

    const build_step = b.step("build", "Build netperf server and client");
    build_step.dependOn(b.getInstallStep());
    b.default_step = build_step;
}
