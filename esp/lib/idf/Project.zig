//! Project describes the structure of a Zig-backed ESP-IDF project.
//!
//! Purpose:
//! - represent the logical layout of one ESP-IDF project
//! - collect the app's component requirements and any local component definitions
//! - preserve the original source locations for every file and archive that belongs to the project
//!
//! Construction:
//! - `App.zig` builds and fills a `Project`
//! - the project keeps references to the original component inputs instead of copying files immediately
//!
//! Extraction:
//! - `Project.extract()` produces a lean `Extracted` description
//! - `Extracted` contains the information that host tools need to materialize a full IDF project
//! - tools can use `Extracted` to create the staged project directory structure, copy files, and write generated build files
//!
//! In short, `Project.zig` is the data model for an ESP-IDF project, while the
//! tools consume its extracted form to build the actual on-disk IDF project.
const std = @import("std");
const BuildContext = @import("BuildContext.zig");
const Component = @import("Component.zig");

const Self = @This();
const Module = std.Build.Module;
const grt_idf_requires = [_][]const u8{
    "freertos",
    "heap",
    "esp_hw_support",
    "esp_timer",
    "lwip",
    "mbedtls",
};
const grt_source_files = [_][]const u8{
    "std/heap/binding.c",
    "std/thread/binding.c",
    "std/crypto/binding.c",
    "sync/channel/binding.c",
    "time/binding.c",
    "net/binding.c",
};
const embed_idf_requires = [_][]const u8{
    "esp_driver_i2c",
};
const embed_source_files = [_][]const u8{
    "i2c/binding.c",
};

owner: *std.Build,
context: ?BuildContext.BuildContext = null,
name: []const u8,
entry: *Module,
entry_component: *Component,
requirements: std.StringArrayHashMapUnmanaged(Requirement) = .empty,

const Requirement = struct {
    component: ?*Component = null,
};

pub const Extracted = struct {
    name: []const u8,
    entry_name: []const u8,
    requirements: []const RequirementExtracted,

    pub const RequirementExtracted = struct {
        name: []const u8,
        component: ?Component.Extracted,
    };
};

/// Creates a project from a resolved build context.
///
/// The caller provides the app entry module plus any additional app
/// components, while `Project` still injects its implicit IDF-facing
/// components and requirements.
pub fn create(
    b: *std.Build,
    bctx: BuildContext.BuildContext,
    entry: *Module,
    components: []const *Component,
) *Self {
    const project = b.allocator.create(Self) catch @panic("OOM");
    project.* = .{
        .owner = b,
        .context = bctx,
        .name = "app",
        .entry = entry,
        .entry_component = undefined,
    };
    project.entry_component = project.createEntryComponent();
    project.addComponent(project.entry_component);
    _ = project.addGrtComponent();
    _ = project.addEmbedComponent();
    for (components) |component| {
        project.addComponent(component);
        project.addEntryRequire(component.name);
    }
    return project;
}

fn addGrtComponent(project: *Self) *Component {
    const bctx = project.context orelse
        std.debug.panic("idf.Project.addGrtComponent() requires project.context", .{});

    const component = Component.create(project.owner, .{
        .name = "grt",
    });

    for (grt_idf_requires) |component_name| {
        component.addRequire(component_name);
    }

    const grt_root = bctx.esp_zig_root.path(project.owner, "lib/grt");
    var source_files = std.ArrayList([]const u8).empty;
    defer source_files.deinit(project.owner.allocator);
    for (grt_source_files) |source_file| {
        source_files.append(project.owner.allocator, project.owner.dupe(source_file)) catch @panic("OOM");
    }

    if (source_files.items.len == 0) {
        const stub_files = project.owner.addWriteFiles();
        const stub_source = stub_files.add("grt_stub.c", "void espz_grt_stub(void) {}\n");
        component.addCSourceFile(.{ .file = stub_source });
    } else {
        component.addCSourceFiles(.{
            .root = grt_root,
            .files = source_files.items,
        });
    }

    project.addComponent(component);
    project.addEntryRequire(component.name);
    return component;
}

fn addEmbedComponent(project: *Self) *Component {
    const bctx = project.context orelse
        std.debug.panic("idf.Project.addEmbedComponent() requires project.context", .{});

    const component = Component.create(project.owner, .{
        .name = "esp_embed",
    });

    for (embed_idf_requires) |component_name| {
        component.addRequire(component_name);
    }

    component.addCSourceFiles(.{
        .root = bctx.esp_zig_root.path(project.owner, "lib/embed"),
        .files = &embed_source_files,
    });

    project.addComponent(component);
    project.addEntryRequire(component.name);
    return component;
}

fn createEntryComponent(project: *Self) *Component {
    const bctx = project.context orelse
        std.debug.panic("idf.Project.createEntryComponent() requires project.context", .{});
    const component = Component.create(project.owner, .{
        .name = "zig_entry",
    });
    const entry_object = project.owner.addObject(.{
        .name = "zig_entry",
        .root_module = project.entry,
    });
    component.addArtifact(entry_object);

    if (bctx.target.result.cpu.arch == .xtensa and
        bctx.target.result.os.tag == .freestanding)
    {
        const shim_object = project.owner.addObject(.{
            .name = "zig_shim",
            .root_module = project.owner.createModule(.{
                .root_source_file = bctx.esp_zig_root.path(project.owner, "lib/idf/zig_shim/shim.zig"),
                .target = project.entry.resolved_target orelse bctx.target,
                .optimize = project.entry.optimize,
            }),
        });
        component.addArtifact(shim_object);
    }

    return component;
}

pub fn addComponent(project: *Self, component: *Component) void {
    addRequirement(project, component.name, component);
}

pub fn extract(project: *const Self) !Extracted {
    const b = project.owner;

    const requirements = try b.allocator.alloc(Extracted.RequirementExtracted, project.requirements.count());
    for (project.requirements.keys(), project.requirements.values(), 0..) |name, requirement, idx| {
        requirements[idx] = .{
            .name = b.dupe(name),
            .component = if (requirement.component) |component|
                try component.extract(try std.fs.path.join(b.allocator, &.{ "components", name }))
            else
                null,
        };
    }

    const extracted: Extracted = .{
        .name = b.dupe(project.name),
        .entry_name = b.dupe(project.entry_component.name),
        .requirements = requirements,
    };
    return extracted;
}

fn addEntryRequire(project: *Self, name: []const u8) void {
    if (std.mem.eql(u8, project.entry_component.name, name)) return;
    project.entry_component.addRequire(name);
}

fn addRequirement(project: *Self, name: []const u8, component: ?*Component) void {
    if (project.requirements.getPtr(name)) |existing| {
        if (component) |new_component| {
            if (existing.component) |current_component| {
                if (current_component != new_component) {
                    std.debug.panic("duplicate project component name '{s}'", .{name});
                }
            } else {
                existing.component = new_component;
            }
        }
        return;
    }

    project.requirements.put(project.owner.allocator, project.owner.dupe(name), .{
        .component = component,
    }) catch @panic("OOM");
}

fn createTestBuild(arena: std.mem.Allocator) !*std.Build {
    const graph: *std.Build.Graph = try arena.create(std.Build.Graph);
    graph.* = .{
        .arena = arena,
        .cache = .{
            .gpa = arena,
            .manifest_dir = std.fs.cwd(),
        },
        .zig_exe = "test",
        .env_map = std.process.EnvMap.init(arena),
        .global_cache_root = .{ .path = "test", .handle = std.fs.cwd() },
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(.{}),
        },
        .zig_lib_directory = std.Build.Cache.Directory.cwd(),
        .time_report = false,
    };

    return std.Build.create(
        graph,
        .{ .path = "test", .handle = std.fs.cwd() },
        .{ .path = "test", .handle = std.fs.cwd() },
        &.{},
    );
}

test "extract returns lean idf project description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const b = try createTestBuild(arena);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("component-src/include");
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/wifi.c",
        .data = "int espz_wifi_helper(void) { return 42; }\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "component-src/include/wifi.h",
        .data = "#pragma once\nint espz_wifi_helper(void);\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "libzig_entry.a",
        .data = "fake archive\n",
    });

    const tmp_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const source_root = try std.fs.path.join(arena, &.{ tmp_root, "component-src" });
    const include_root = try std.fs.path.join(arena, &.{ source_root, "include" });
    const archive_path = try std.fs.path.join(arena, &.{ tmp_root, "libzig_entry.a" });

    const helper = Component.create(b, .{ .name = "esp_main_helper" });
    helper.addCSourceFiles(.{
        .root = .{ .cwd_relative = source_root },
        .files = &.{"wifi.c"},
    });
    helper.addIncludePath(.{ .cwd_relative = include_root });
    helper.addRequire("esp_wifi");
    helper.addPrivRequire("nvs_flash");

    const entry_sources = b.addWriteFiles();
    const entry_root = entry_sources.add("entry.zig",
        \\export fn zig_esp_main() void {}
        \\
    );
    const entry_module = b.createModule(.{
        .root_source_file = entry_root,
    });

    const project = b.allocator.create(Self) catch @panic("OOM");
    project.* = .{
        .owner = b,
        .name = "embed_compat",
        .entry = entry_module,
        .entry_component = undefined,
    };
    addRequirement(project, "esp_event", null);
    addRequirement(project, "esp_event", null);

    const zig_entry = Component.create(b, .{ .name = "zig_entry" });
    zig_entry.addArchiveFile(.{
        .relative_path = "zig_entry.a",
        .file = .{ .cwd_relative = archive_path },
    });
    project.entry_component = zig_entry;
    project.entry_component.addRequire("esp_event");
    project.entry_component.addRequire("esp_main_helper");

    project.addComponent(zig_entry);
    project.addComponent(helper);

    const extracted = try project.extract();

    try std.testing.expectEqualStrings("embed_compat", extracted.name);
    try std.testing.expectEqualStrings("zig_entry", extracted.entry_name);
    try std.testing.expectEqual(@as(usize, 3), extracted.requirements.len);
    try std.testing.expectEqualStrings("esp_event", extracted.requirements[0].name);
    try std.testing.expect(extracted.requirements[0].component == null);
    try std.testing.expectEqualStrings("zig_entry", extracted.requirements[1].name);
    try std.testing.expect(extracted.requirements[1].component != null);
    try std.testing.expectEqualStrings("components/zig_entry/zig_entry.a", extracted.requirements[1].component.?.archives[0].idf_project_path);
    try std.testing.expectEqualStrings(archive_path, extracted.requirements[1].component.?.archives[0].original_path.getPath(b));
    try std.testing.expectEqualStrings("esp_event", extracted.requirements[1].component.?.requires[0]);
    try std.testing.expectEqualStrings("esp_main_helper", extracted.requirements[1].component.?.requires[1]);
    try std.testing.expectEqualStrings("esp_main_helper", extracted.requirements[2].name);
    try std.testing.expect(extracted.requirements[2].component != null);
    try std.testing.expectEqualStrings("components/esp_main_helper/wifi.c", extracted.requirements[2].component.?.srcs[0].idf_project_path);
    try std.testing.expectEqualStrings("components/esp_main_helper/include", extracted.requirements[2].component.?.include_dirs[0].idf_project_path);
}
