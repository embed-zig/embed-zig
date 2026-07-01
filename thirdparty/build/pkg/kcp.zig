const std = @import("std");
const builtin = @import("builtin");
const buildtools = @import("buildtools");

const upstream_remote_url = "https://github.com/skywind3000/kcp.git";
const upstream_revision = "c102b9b7f51012ca8253ab1cca596e560a8e0319";
const optimized_patch_files: []const []const u8 = &.{
    "pkg/kcp/patches/0001-embed-zig-kcp-integration.patch",
    "pkg/kcp/patches/0002-embed-zig-kcp-optimizations.patch",
    "pkg/kcp/patches/0003-embed-zig-kcp-diagnostics.patch",
};

var library: ?*std.Build.Step.Compile = null;

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const upstream = buildtools.addGitRepo(b, .{
        .remote_url = upstream_remote_url,
        .revision = upstream_revision,
        .cache_namespace = "kcp-upstream",
        .step_name = "kcp.git-repo.ensure",
    });
    const optimized = addPatchedUpstream(b, upstream, "optimized-v1", optimized_patch_files);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "kcp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    addCommonInputs(b, lib.root_module, optimized.includePath("."));
    lib.root_module.addCSourceFile(.{
        .file = optimized.sourcePath("ikcp.c"),
    });
    if (!isNativeTarget(target)) {
        b.installArtifact(lib);
    }
    optimized.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/kcp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCommonInputs(b, mod, optimized.includePath("."));
    b.modules.put("kcp", mod) catch @panic("OOM");
    library = lib;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("kcp") orelse @panic("kcp module missing");
    const lib = library orelse @panic("kcp library missing");
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addObjectFile(lib.getEmittedBin());
}

fn addCommonInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    include_path: std.Build.LazyPath,
) void {
    mod.addIncludePath(include_path);
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) });
    }
}

fn isNativeTarget(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch == builtin.cpu.arch and target.result.os.tag == builtin.os.tag;
}

const PatchedUpstream = struct {
    b: *std.Build,
    root_path: []const u8,
    ready: *std.Build.Step,

    fn root(self: PatchedUpstream) std.Build.LazyPath {
        return .{ .cwd_relative = self.root_path };
    }

    fn path(self: PatchedUpstream, sub_path: []const u8) std.Build.LazyPath {
        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".")) {
            return self.root();
        }
        return .{ .cwd_relative = joinPath(self.b, self.root_path, sub_path) };
    }

    fn sourcePath(self: PatchedUpstream, sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    fn includePath(self: PatchedUpstream, sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    fn dependOn(self: PatchedUpstream, step: *std.Build.Step) void {
        step.dependOn(self.ready);
    }
};

const PatchStep = struct {
    step: std.Build.Step,
    upstream_root_path: []const u8,
    dest_path: []const u8,
    patch_paths: []const []const u8,
    marker: []const u8,

    fn create(
        b: *std.Build,
        upstream_root_path: []const u8,
        dest_path: []const u8,
        patch_paths: []const []const u8,
        marker: []const u8,
    ) *PatchStep {
        const self = b.allocator.create(PatchStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "kcp.patch-upstream.ensure",
                .owner = b,
                .makeFn = make,
            }),
            .upstream_root_path = b.dupe(upstream_root_path),
            .dest_path = b.dupe(dest_path),
            .patch_paths = dupeStringSlice(b, patch_paths),
            .marker = b.dupe(marker),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        const self: *PatchStep = @alignCast(@fieldParentPtr("step", step));
        var arena = std.heap.ArenaAllocator.init(options.gpa);
        defer arena.deinit();
        try ensurePatched(arena.allocator(), self.upstream_root_path, self.dest_path, self.patch_paths, self.marker);
    }
};

fn addPatchedUpstream(
    b: *std.Build,
    upstream: buildtools.GitCheckout,
    patch_set_name: []const u8,
    patch_files: []const []const u8,
) PatchedUpstream {
    const dest_path = b.cache_root.join(b.allocator, &.{
        "kcp-patched-upstream",
        upstream_revision,
        patchSetKey(patch_set_name),
    }) catch @panic("OOM");

    const resolved_patch_files = b.allocator.alloc([]const u8, patch_files.len) catch @panic("OOM");
    for (patch_files, 0..) |patch_file, i| {
        resolved_patch_files[i] = b.pathFromRoot(patch_file);
    }

    const patch_step = PatchStep.create(
        b,
        upstream.source_root_path,
        dest_path,
        resolved_patch_files,
        patchSetKey(patch_set_name),
    );
    patch_step.step.dependOn(&upstream.steps.graph.ready);

    return .{
        .b = b,
        .root_path = dest_path,
        .ready = &patch_step.step,
    };
}

fn ensurePatched(
    gpa: std.mem.Allocator,
    upstream_root_path: []const u8,
    dest_path: []const u8,
    patch_paths: []const []const u8,
    marker: []const u8,
) !void {
    const patch_marker = try computePatchMarker(gpa, marker, patch_paths);
    const dest_abs = try absolutePath(gpa, dest_path);
    defer gpa.free(dest_abs);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{dest_abs});
    defer gpa.free(lock_path);

    const parent = std.fs.path.dirname(dest_abs) orelse ".";
    try std.fs.cwd().makePath(parent);

    var lock = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close();

    if (try markerMatches(gpa, dest_abs, patch_marker)) return;

    std.fs.deleteTreeAbsolute(dest_abs) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try std.fs.makeDirAbsolute(dest_abs);
    errdefer std.fs.deleteTreeAbsolute(dest_abs) catch {};

    const upstream_abs = try absolutePath(gpa, upstream_root_path);
    defer gpa.free(upstream_abs);

    try copyUpstreamFile(gpa, upstream_abs, dest_abs, "ikcp.c");
    try copyUpstreamFile(gpa, upstream_abs, dest_abs, "ikcp.h");
    try copyUpstreamFile(gpa, upstream_abs, dest_abs, "LICENSE");

    for (patch_paths) |patch_path| {
        const patch_abs = try absolutePath(gpa, patch_path);
        defer gpa.free(patch_abs);
        if (builtin.os.tag == .windows) {
            try runCommand(gpa, dest_abs, &.{ "git", "apply", "--unsafe-paths", patch_abs });
        } else {
            try runCommand(gpa, dest_abs, &.{ "patch", "-p1", "-i", patch_abs });
        }
    }

    var dest_dir = try std.fs.openDirAbsolute(dest_abs, .{});
    defer dest_dir.close();
    try dest_dir.writeFile(.{ .sub_path = ".embed-zig-kcp-patchset", .data = patch_marker, .flags = .{} });
}

fn copyUpstreamFile(gpa: std.mem.Allocator, upstream_abs: []const u8, dest_abs: []const u8, name: []const u8) !void {
    const src = try std.fs.path.join(gpa, &.{ upstream_abs, name });
    defer gpa.free(src);
    const dst = try std.fs.path.join(gpa, &.{ dest_abs, name });
    defer gpa.free(dst);
    try std.fs.copyFileAbsolute(src, dst, .{});
}

fn computePatchMarker(gpa: std.mem.Allocator, marker: []const u8, patch_paths: []const []const u8) ![]const u8 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(marker);
    for (patch_paths) |patch_path| {
        hash.update(patch_path);
        const patch = try std.fs.cwd().readFileAlloc(gpa, patch_path, std.math.maxInt(usize));
        hash.update(patch);
    }
    return std.fmt.allocPrint(gpa, "{s}:{x}", .{ marker, hash.final() });
}

fn markerMatches(gpa: std.mem.Allocator, dest_abs: []const u8, marker: []const u8) !bool {
    var dest_dir = std.fs.openDirAbsolute(dest_abs, .{}) catch return false;
    defer dest_dir.close();

    const prev = dest_dir.readFileAlloc(gpa, ".embed-zig-kcp-patchset", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer gpa.free(prev);

    const trimmed = std.mem.trimRight(u8, prev, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, marker);
}

fn runCommand(gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }

    if (result.stderr.len != 0) {
        std.log.err("command failed: {s}", .{result.stderr});
    }
    return error.CommandFailed;
}

fn absolutePath(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return gpa.dupe(u8, path);
    }
    const cwd_abs = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(cwd_abs);
    return std.fs.path.join(gpa, &.{ cwd_abs, path });
}

fn joinPath(b: *std.Build, base: []const u8, sub_path: []const u8) []const u8 {
    return std.fs.path.join(b.allocator, &.{ base, sub_path }) catch @panic("OOM");
}

fn dupeStringSlice(b: *std.Build, values: []const []const u8) []const []const u8 {
    const copied = b.allocator.alloc([]const u8, values.len) catch @panic("OOM");
    @memcpy(copied, values);
    return copied;
}

fn patchSetKey(patch_set_name: []const u8) []const u8 {
    return patch_set_name;
}
