const std = @import("std");

const Self = @This();

owner: *std.Build,
name: []const u8,
c_source_file: ?std.Build.LazyPath = null,
include_dirs: []const std.Build.LazyPath = &.{},
requires: []const []const u8 = &.{},
artifacts: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty,
archive_files: std.ArrayListUnmanaged(ArchiveFile) = .empty,

pub const Options = struct {
    name: []const u8,
    c_source_file: ?std.Build.LazyPath = null,
    include_dirs: []const std.Build.LazyPath = &.{},
    requires: []const []const u8 = &.{},
};

pub const ArchiveFile = struct {
    relative_path: []const u8,
    file: std.Build.LazyPath,
};

pub fn create(b: *std.Build, options: Options) Self {
    validateComponentNameOrPanic(options.name);
    return .{
        .owner = b,
        .name = b.dupe(options.name),
        .c_source_file = if (options.c_source_file) |path| path.dupe(b) else null,
        .include_dirs = dupeLazyPaths(b, options.include_dirs),
        .requires = b.dupeStrings(options.requires),
    };
}

pub fn addArtifact(component: *Self, artifact: *std.Build.Step.Compile) void {
    if (!artifactIsStaticLibrary(artifact) and !artifactIsObject(artifact)) {
        std.debug.panic(
            "armino.Component '{s}' addArtifact() expects a static library or object artifact, found kind={s} linkage={?}",
            .{ component.name, @tagName(artifact.kind), artifact.linkage },
        );
    }

    component.artifacts.append(component.owner.allocator, artifact) catch @panic("OOM");
}

pub fn addArchiveFile(component: *Self, archive: ArchiveFile) void {
    validateRelativePathOrPanic(component.name, archive.relative_path, "archive path");
    if (!std.mem.endsWith(u8, archive.relative_path, ".a")) {
        std.debug.panic(
            "armino.Component '{s}' archive path must end with .a, found '{s}'",
            .{ component.name, archive.relative_path },
        );
    }

    component.archive_files.append(component.owner.allocator, .{
        .relative_path = component.owner.dupe(archive.relative_path),
        .file = archive.file.dupe(component.owner),
    }) catch @panic("OOM");
}

fn artifactIsStaticLibrary(artifact: *std.Build.Step.Compile) bool {
    return artifact.kind == .lib and artifact.linkage == .static;
}

fn artifactIsObject(artifact: *std.Build.Step.Compile) bool {
    return artifact.kind == .obj;
}

fn dupeLazyPaths(b: *std.Build, paths: []const std.Build.LazyPath) []const std.Build.LazyPath {
    const duped = b.allocator.alloc(std.Build.LazyPath, paths.len) catch @panic("OOM");
    for (paths, 0..) |path, idx| {
        duped[idx] = path.dupe(b);
    }
    return duped;
}

fn validateComponentNameOrPanic(name: []const u8) void {
    if (name.len == 0) {
        std.debug.panic("armino component name cannot be empty", .{});
    }
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_';
        if (!ok) {
            std.debug.panic("invalid armino component name '{s}'", .{name});
        }
    }
}

fn validateRelativePathOrPanic(component_name: []const u8, path: []const u8, what: []const u8) void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) {
        std.debug.panic("armino.Component '{s}' requires a relative {s}, found '{s}'", .{ component_name, what, path });
    }
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            std.debug.panic("armino.Component '{s}' {s} must stay inside the component directory, found '{s}'", .{ component_name, what, path });
        }
    }
}
