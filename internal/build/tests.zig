const std = @import("std");

const StepSpec = struct {
    name: []const u8,
    description: []const u8,
};

const NamedStep = struct {
    name: []const u8,
    step: *std.Build.Step,
};

fn lessThan(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return a.len < b.len;
}

fn insertStepSpec(gpa: std.mem.Allocator, specs: *std.ArrayList(StepSpec), spec: StepSpec) void {
    var idx: usize = 0;
    while (idx < specs.items.len and lessThan(specs.items[idx].name, spec.name)) : (idx += 1) {}
    specs.insert(gpa, idx, spec) catch @panic("OOM");
}

fn getStep(steps: []const NamedStep, name: []const u8) *std.Build.Step {
    for (steps) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.step;
    }
    @panic("test step missing");
}

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime Libraries: type,
    comptime Packages: type,
) void {
    const TestType = struct {
        label: []const u8,
        description: []const u8,
        parent_name: []const u8,
    };
    const test_types = [_]TestType{
        .{ .label = "benchmark", .description = "Run benchmark tests", .parent_name = "test-benchmark" },
        .{ .label = "cork", .description = "Run cork tests", .parent_name = "test-cork" },
        .{ .label = "integration", .description = "Run integration tests", .parent_name = "test-integration" },
        .{ .label = "unit", .description = "Run unit tests", .parent_name = "test-unit" },
    };

    var step_specs: std.ArrayList(StepSpec) = .empty;
    defer step_specs.deinit(b.allocator);

    insertStepSpec(b.allocator, &step_specs, .{ .name = "test", .description = "Run all tests" });
    for (test_types) |test_type| {
        insertStepSpec(b.allocator, &step_specs, .{ .name = test_type.parent_name, .description = test_type.description });
    }

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        const mod_name = decl.name;
        insertStepSpec(b.allocator, &step_specs, .{
            .name = b.fmt("test-all-{s}", .{mod_name}),
            .description = b.fmt("Run all {s} tests", .{mod_name}),
        });
        for (test_types) |test_type| {
            insertStepSpec(b.allocator, &step_specs, .{
                .name = b.fmt("test-{s}-{s}", .{ test_type.label, mod_name }),
                .description = b.fmt("Run {s} {s} tests", .{ test_type.label, mod_name }),
            });
        }
    }

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        if (b.modules.get(decl.name) != null) {
            insertStepSpec(b.allocator, &step_specs, .{
                .name = b.fmt("test-all-{s}", .{decl.name}),
                .description = b.fmt("Run all {s} tests", .{decl.name}),
            });
            for (test_types) |test_type| {
                insertStepSpec(b.allocator, &step_specs, .{
                    .name = b.fmt("test-{s}-{s}", .{ test_type.label, decl.name }),
                    .description = b.fmt("Run {s} {s} tests", .{ test_type.label, decl.name }),
                });
            }
        }
    }

    var steps: std.ArrayList(NamedStep) = .empty;
    defer steps.deinit(b.allocator);

    for (step_specs.items) |spec| {
        steps.append(b.allocator, .{
            .name = spec.name,
            .step = b.step(spec.name, spec.description),
        }) catch @panic("OOM");
    }

    const test_step = getStep(steps.items, "test");
    for (test_types) |test_type| {
        test_step.dependOn(getStep(steps.items, test_type.parent_name));
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("lib/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("tests", test_mod) catch @panic("OOM");

    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_stdrt_dep = b.dependency("glib_stdrt", .{
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("glib", glib_dep.module("glib"));
    test_mod.addImport("glib_stdrt", glib_stdrt_dep.module("glib_stdrt"));

    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        const mod = b.modules.get(decl.name) orelse @panic("test dependency missing");
        test_mod.addImport(decl.name, mod);
    }
    inline for (@typeInfo(Libraries).@"struct".decls) |decl| {
        const mod_name = decl.name;
        const all_step = getStep(steps.items, b.fmt("test-all-{s}", .{mod_name}));
        for (test_types) |test_type| {
            const module_step = getStep(steps.items, b.fmt("test-{s}-{s}", .{ test_type.label, mod_name }));
            const parent_step = getStep(steps.items, test_type.parent_name);
            const default_filter = b.fmt("{s}/{s}/", .{ mod_name, test_type.label });
            const compile_test = if (std.mem.eql(u8, mod_name, "net") and std.mem.eql(u8, test_type.label, "integration"))
                b.addTest(.{
                    .root_module = test_mod,
                    .filters = &.{ default_filter, "net/integration2/" },
                })
            else
                b.addTest(.{
                    .root_module = test_mod,
                    .filters = &.{default_filter},
                });
            const run_test = b.addRunArtifact(compile_test);
            run_test.setName(b.fmt("{s}:{s}", .{ mod_name, test_type.label }));
            parent_step.dependOn(&run_test.step);
            module_step.dependOn(&run_test.step);
            all_step.dependOn(&run_test.step);
        }
    }

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        if (b.modules.get(decl.name)) |mod| {
            const package_impl = @field(Packages, decl.name);
            const link_hook: *const fn (b: *std.Build, compile: *std.Build.Step.Compile) void = package_impl.linkTest;
            const all_step = getStep(steps.items, b.fmt("test-all-{s}", .{decl.name}));

            for (test_types) |test_type| {
                const module_step = getStep(steps.items, b.fmt("test-{s}-{s}", .{ test_type.label, decl.name }));
                const parent_step = getStep(steps.items, test_type.parent_name);

                const compile_test = b.addTest(.{
                    .root_module = mod,
                    .filters = &.{b.fmt("{s}/{s}/", .{ decl.name, test_type.label })},
                });
                link_hook(b, compile_test);
                const run_test = b.addRunArtifact(compile_test);
                run_test.setName(b.fmt("{s}:{s}", .{ decl.name, test_type.label }));
                parent_step.dependOn(&run_test.step);
                module_step.dependOn(&run_test.step);
                all_step.dependOn(&run_test.step);
            }
        }
    }
}
