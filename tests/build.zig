const std = @import("std");
const tests = @import("tests.zig");

const StepSpec = struct {
    name: []const u8,
    description: []const u8,
};

const TestLabel = struct {
    label: []const u8,
    description: []const u8,
    parent_name: []const u8,
};

const test_labels = [_]TestLabel{
    .{ .label = "integration", .description = "Run integration tests", .parent_name = "test-integration" },
    .{ .label = "unit", .description = "Run unit tests", .parent_name = "test-unit" },
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const test_filter_override = b.option([]const u8, "test-filter", "Run tests matching this filter instead of the step default filter");
    const root_test_module = createModule(b, target, optimize);
    var step_specs: std.ArrayList(StepSpec) = .empty;
    defer step_specs.deinit(b.allocator);

    step_specs.append(b.allocator, .{ .name = "test", .description = "Run all tests" }) catch @panic("OOM");
    for (test_labels) |test_label| {
        step_specs.append(b.allocator, .{ .name = test_label.parent_name, .description = test_label.description }) catch @panic("OOM");
    }
    inline for (tests.modules) |test_module| {
        const meta = test_module.meta;
        step_specs.append(b.allocator, .{
            .name = b.fmt("test-all-{s}", .{stepModuleName(b, meta.module)}),
            .description = b.fmt("Run all {s} tests", .{meta.module}),
        }) catch @panic("OOM");
        inline for (meta.labels) |label| {
            step_specs.append(b.allocator, .{
                .name = b.fmt("test-{s}-{s}", .{ label, stepModuleName(b, meta.module) }),
                .description = b.fmt("Run {s} {s} tests", .{ label, meta.module }),
            }) catch @panic("OOM");
        }
    }
    std.mem.sort(StepSpec, step_specs.items, {}, stepSpecLessThan);

    var steps = std.StringHashMap(*std.Build.Step).init(b.allocator);
    defer steps.deinit();

    for (step_specs.items) |spec| {
        steps.put(spec.name, b.step(spec.name, spec.description)) catch @panic("OOM");
    }

    const test_step = steps.get("test").?;
    for (test_labels) |test_label| {
        test_step.dependOn(steps.get(test_label.parent_name).?);
    }

    inline for (tests.modules) |test_module| {
        const meta = test_module.meta;
        inline for (meta.labels) |label| {
            inline for (test_labels) |test_label| {
                if (comptime std.mem.eql(u8, label, test_label.label)) {
                    const parent_step = steps.get(test_label.parent_name).?;
                    const module_step_name = stepModuleName(b, meta.module);
                    const module_step = steps.get(b.fmt("test-{s}-{s}", .{ label, module_step_name })).?;
                    const all_step = steps.get(b.fmt("test-all-{s}", .{module_step_name})).?;
                    const test_filter = b.fmt("{s}/{s}/", .{ meta.module, label });
                    const filters: []const []const u8 = if (test_filter_override) |filter|
                        &.{filter}
                    else
                        &.{test_filter};
                    const compile_test = b.addTest(.{
                        .root_module = root_test_module,
                        .filters = filters,
                    });
                    const run_test = b.addRunArtifact(compile_test);
                    run_test.setName(b.fmt("{s}:{s}", .{ meta.module, label }));
                    parent_step.dependOn(&run_test.step);
                    module_step.dependOn(&run_test.step);
                    all_step.dependOn(&run_test.step);
                }
            }
        }
    }
}

fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const glib_dep = b.dependency("glib", .{ .target = target, .optimize = optimize });
    const gstd_dep = b.dependency("gstd", .{ .target = target, .optimize = optimize });
    const embed_dep = b.dependency("embed", .{ .target = target, .optimize = optimize });
    const thirdparty_dep = b.dependency("thirdparty", .{ .target = target, .optimize = optimize });
    const gstd = gstd_dep.module("gstd");

    const mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("gstd", gstd);
    mod.addImport("embed", embed_dep.module("embed"));
    mod.addImport("core_bluetooth", thirdparty_dep.module("core_bluetooth"));
    mod.addImport("core_wlan", thirdparty_dep.module("core_wlan"));
    mod.addImport("lvgl", thirdparty_dep.module("lvgl"));
    mod.addImport("lvgl_osal", thirdparty_dep.module("lvgl_osal"));
    mod.addImport("mbedtls", thirdparty_dep.module("mbedtls"));
    mod.addImport("opus", thirdparty_dep.module("opus"));
    mod.addImport("portaudio", thirdparty_dep.module("portaudio"));
    mod.addImport("speexdsp", thirdparty_dep.module("speexdsp"));
    mod.addImport("stb_truetype", thirdparty_dep.module("stb_truetype"));

    return mod;
}

fn stepModuleName(b: *std.Build, module: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, module, "/", "-") catch @panic("OOM");
}

fn stepSpecLessThan(_: void, a: StepSpec, b: StepSpec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
