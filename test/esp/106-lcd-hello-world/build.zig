const std = @import("std");
const esp = @import("esp");

const default_board_file = "board/esp32s3_szp.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_config = b.option([]const u8, "board", "Board sdkconfig profile Zig file path") orelse default_board_file;
    const build_dir = b.option([]const u8, "build_dir", "Directory for all generated workflow files") orelse "build";

    const rt = esp.idf.build.externalRuntimeOptionsFromBuild(b);

    const esp_dep = b.dependency("esp", .{});
    const embed_zig_dep = esp_dep.builder.dependency("embed_zig", .{});

    const extra_modules = b.allocator.alloc(esp.idf.build.ExtraZigModule, 3) catch @panic("OOM");
    extra_modules[0] = .{ .name = "board_hw", .path = b.path("board/esp32s3_szp_hw.zig") };
    extra_modules[1] = .{ .name = "test_firmware", .path = embed_zig_dep.path("test/firmware/106-lcd-hello-world/app.zig") };
    extra_modules[2] = .{ .name = "embed", .path = b.path("src/embed.zig") };

    _ = esp.idf.build.registerApp(b, .{
        .target = target,
        .optimize = optimize,
        .app_name = "lcd_hello_world_106",
        .build_config = build_config,
        .build_dir = build_dir,
        .runtime = rt,
        .extra_zig_modules = extra_modules,
    });
}
