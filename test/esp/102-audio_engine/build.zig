const std = @import("std");
const espz = @import("espz");

const default_board_file = "board/esp32s3_korvo2.zig";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const board_file = b.option([]const u8, "board", "Board sdkconfig profile Zig file path") orelse default_board_file;
    const build_dir = b.option([]const u8, "build_dir", "Directory for all generated workflow files") orelse "build";

    const rt = espz.workflow.externalRuntimeOptionsFromBuild(b);

    const embed_zig_dep = b.dependency("embed_zig", .{});

    const runtime_path = embed_zig_dep.path("src/runtime/root.zig");
    const hal_path = embed_zig_dep.path("src/hal/root.zig");
    const runtime_esp_path = embed_zig_dep.path("src/runtime/esp/root.zig");
    const hal_esp_path = embed_zig_dep.path("src/hal/esp/root.zig");
    const event_path = embed_zig_dep.path("src/pkg/event/root.zig");
    const flux_path = embed_zig_dep.path("src/pkg/flux/root.zig");
    const app_runtime_path = embed_zig_dep.path("src/pkg/app/root.zig");
    const audio_path = embed_zig_dep.path("src/pkg/audio/root.zig");
    const test_firmware_path = embed_zig_dep.path("test/firmware/root.zig");

    const ui_render_path = embed_zig_dep.path("src/pkg/ui/render/framebuffer/root.zig");
    const es7210_driver_path = embed_zig_dep.path("src/pkg/drivers/es7210/src.zig");
    const es8311_driver_path = embed_zig_dep.path("src/pkg/drivers/es8311/src.zig");

    const extra_modules = b.allocator.alloc(espz.workflow.ExtraZigModule, 13) catch @panic("OOM");
    extra_modules[0] = .{ .name = "embed/runtime", .path = runtime_path };
    extra_modules[1] = .{ .name = "embed/hal", .path = hal_path };
    extra_modules[2] = .{ .name = "es7210_driver", .path = es7210_driver_path };
    extra_modules[3] = .{ .name = "es8311_driver", .path = es8311_driver_path };
    extra_modules[4] = .{ .name = "runtime_esp", .path = runtime_esp_path, .deps = &.{"embed/runtime"} };
    extra_modules[5] = .{ .name = "hal_esp", .path = hal_esp_path, .deps = &.{ "embed/hal", "es7210_driver", "es8311_driver" } };
    extra_modules[6] = .{ .name = "embed/event", .path = event_path, .deps = &.{ "embed/runtime", "embed/hal" } };
    extra_modules[7] = .{ .name = "embed/flux", .path = flux_path };
    extra_modules[8] = .{ .name = "embed/app", .path = app_runtime_path, .deps = &.{ "embed/runtime", "embed/event", "embed/flux" } };
    extra_modules[9] = .{ .name = "embed/audio", .path = audio_path, .deps = &.{"embed/runtime"} };
    extra_modules[10] = .{ .name = "embed/ui/render", .path = ui_render_path };
    extra_modules[11] = .{ .name = "test_firmware", .path = test_firmware_path, .deps = &.{ "embed/runtime", "embed/hal", "embed/event", "embed/flux", "embed/app", "embed/audio", "embed/ui/render" } };
    extra_modules[12] = .{ .name = "embed/ui/led_strip", .path = embed_zig_dep.path("src/pkg/ui/led_strip/root.zig"), .deps = &.{"embed/hal"} };

    _ = espz.registerApp(b, .{
        .target = target,
        .optimize = optimize,
        .app_name = "audio_engine_102",
        .board_file = board_file,
        .build_dir = build_dir,
        .compile_check_with_idf_module = false,
        .runtime = rt,
        .extra_zig_modules = extra_modules,
    });
}
