const std = @import("std");
const tests = @import("tests.zig");

const StepSpec = struct {
    name: []const u8,
    description: []const u8,
};

const TestLabel = struct {
    label: tests.Label,
    description: []const u8,
    parent_name: []const u8,
};

const test_labels = [_]TestLabel{
    .{ .label = .integration, .description = "Run integration tests", .parent_name = "test-integration" },
    .{ .label = .unit, .description = "Run unit tests", .parent_name = "test-unit" },
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const test_filter_override = b.option([]const u8, "test-filter", "Run tests matching this filter instead of the step default filter");
    const root_test_module = createModule(b, target, optimize);
    switch (target.result.os.tag) {
        .linux => createForTarget(b, test_filter_override, root_test_module, true, false),
        .macos => createForTarget(b, test_filter_override, root_test_module, false, true),
        else => createForTarget(b, test_filter_override, root_test_module, false, false),
    }
}

fn createForTarget(
    b: *std.Build,
    test_filter_override: ?[]const u8,
    root_test_module: *std.Build.Module,
    comptime is_linux: bool,
    comptime is_macos: bool,
) void {
    var step_specs: std.ArrayList(StepSpec) = .empty;
    defer step_specs.deinit(b.allocator);
    var seen_step_specs = std.StringHashMap(void).init(b.allocator);
    defer seen_step_specs.deinit();

    appendStepSpec(b, &step_specs, &seen_step_specs, .{ .name = "test", .description = "Run all tests" });
    for (test_labels) |test_label| {
        appendStepSpec(b, &step_specs, &seen_step_specs, .{
            .name = test_label.parent_name,
            .description = test_label.description,
        });
    }
    inline for (tests.modulesFor(is_linux, is_macos)) |test_module| {
        const meta = test_module.meta;
        const module_step_name = stepModuleName(b, meta.module);
        const all_step_name = b.fmt("test-all-{s}", .{module_step_name});
        appendStepSpec(b, &step_specs, &seen_step_specs, .{
            .name = all_step_name,
            .description = b.fmt("Run all {s} tests", .{meta.module}),
        });
        const meta_label: tests.Label = meta.label;
        const label = labelName(meta_label);
        appendStepSpec(b, &step_specs, &seen_step_specs, .{
            .name = b.fmt("test-{s}-{s}", .{ label, module_step_name }),
            .description = b.fmt("Run {s} {s} tests", .{ label, meta.module }),
        });
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

    inline for (tests.modulesFor(is_linux, is_macos)) |test_module| {
        const meta = test_module.meta;
        inline for (test_labels) |test_label| {
            const meta_label: tests.Label = meta.label;
            if (meta_label == test_label.label) {
                const label = labelName(meta_label);
                const parent_step = steps.get(test_label.parent_name).?;
                const module_step_name = stepModuleName(b, meta.module);
                const module_step = steps.get(b.fmt("test-{s}-{s}", .{ label, module_step_name })).?;
                const all_step = steps.get(b.fmt("test-all-{s}", .{module_step_name})).?;
                const filters: []const []const u8 = if (test_filter_override) |filter|
                    &.{filter}
                else
                    &.{meta.filter};
                const compile_test = b.addTest(.{
                    .root_module = root_test_module,
                    .filters = filters,
                });
                const run_test = b.addRunArtifact(compile_test);
                run_test.setName(meta.filter);
                parent_step.dependOn(&run_test.step);
                module_step.dependOn(&run_test.step);
                all_step.dependOn(&run_test.step);
            }
        }
    }
}

fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const test_target = b.addOptions();
    test_target.addOption(std.Target.Os.Tag, "os_tag", target.result.os.tag);

    const mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", exportedModule(b, "glib"));
    mod.addImport("gstd", exportedModule(b, "gstd"));
    mod.addImport("embed", exportedModule(b, "embed"));
    mod.addImport("openapi", exportedModule(b, "openapi"));
    mod.addImport("codegen", exportedModule(b, "codegen"));
    mod.addImport("desktop", exportedModule(b, "desktop"));
    mod.addImport("core_bluetooth", exportedModule(b, "core_bluetooth"));
    mod.addImport("core_wlan", exportedModule(b, "core_wlan"));
    mod.addOptions("test_target", test_target);
    mod.addImport("lvgl", exportedModule(b, "lvgl"));
    mod.addImport("lvgl_osal", exportedModule(b, "lvgl_osal"));
    mod.addImport("mbedtls", exportedModule(b, "mbedtls"));
    mod.addImport("opus", exportedModule(b, "opus"));
    mod.addImport("portaudio", exportedModule(b, "portaudio"));
    mod.addImport("speexdsp", exportedModule(b, "speexdsp"));
    mod.addImport("stb_truetype", exportedModule(b, "stb_truetype"));

    return mod;
}

fn exportedModule(b: *std.Build, name: []const u8) *std.Build.Module {
    return b.modules.get(name) orelse @panic("missing exported module");
}

fn stepModuleName(b: *std.Build, module: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, module, "/", "-") catch @panic("OOM");
}

fn appendStepSpec(
    b: *std.Build,
    step_specs: *std.ArrayList(StepSpec),
    seen_step_specs: *std.StringHashMap(void),
    spec: StepSpec,
) void {
    if (seen_step_specs.contains(spec.name)) return;
    seen_step_specs.put(spec.name, {}) catch @panic("OOM");
    step_specs.append(b.allocator, spec) catch @panic("OOM");
}

fn labelName(label: tests.Label) []const u8 {
    return switch (label) {
        .integration => "integration",
        .unit => "unit",
    };
}

fn stepSpecLessThan(_: void, a: StepSpec, b: StepSpec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
