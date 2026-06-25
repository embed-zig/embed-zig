const std = @import("std");
const gstd = @import("gstd");

pub const App = @import("desktop/App.zig");
pub const device = @import("device.zig");
pub const http = @import("http.zig");
pub const fs = @import("fs.zig");
pub const log = @import("log.zig");
pub const system = @import("system.zig");
pub const runtime = gstd.runtime;

pub const PlatformConfig = struct {
    bundle_id: []const u8 = "dev.embed.desktop.launcher",
    home_dir: []const u8 = "",
    storage_root: []const u8 = "",
};

pub const PlatformCtx = PlatformCtxWith(.{});

pub fn PlatformCtxWith(comptime config: PlatformConfig) type {
    return struct {
        pub const AudioSystem = device.audio_system.AudioSystem;

        pub fn preferencesProvider(allocator: anytype) !system.preferences.Provider {
            return system.preferences.Provider.init(.{
                .allocator = allocator,
            });
        }

        pub const fs = struct {
            pub const storage_path = "/storage";
            var host_storage_root: ?[]const u8 = null;

            pub fn hasStoragePartition() bool {
                return true;
            }

            pub fn mountStorage() !void {
                const root = try ensureHostStorageRoot();
                gstd.fs.setHostMount(storage_path, root);
                std.log.info("desktop storage mounted {s} -> {s}", .{ storage_path, root });
            }

            pub fn unmountStorage() void {}

            pub fn deleteStoragePath(path: []const u8) !void {
                const root = try ensureHostStorageRoot();
                const host_path = try resolveStoragePath(root, path);
                defer std.heap.page_allocator.free(host_path);
                if (std.fs.path.isAbsolute(host_path)) {
                    std.fs.deleteFileAbsolute(host_path) catch |err| switch (err) {
                        error.IsDir => return std.fs.deleteTreeAbsolute(host_path),
                        error.FileNotFound => return,
                        else => return err,
                    };
                } else {
                    std.fs.cwd().deleteFile(host_path) catch |err| switch (err) {
                        error.IsDir => return std.fs.cwd().deleteTree(host_path),
                        error.FileNotFound => return,
                        else => return err,
                    };
                }
            }

            fn ensureHostStorageRoot() ![]const u8 {
                if (host_storage_root) |root| return root;

                const allocator = std.heap.page_allocator;
                const root = if (config.storage_root.len != 0)
                    try allocator.dupe(u8, config.storage_root)
                else
                    try defaultStorageRoot(allocator);

                errdefer allocator.free(root);
                try ensureHostPath(root);

                host_storage_root = root;
                return root;
            }

            fn defaultStorageRoot(allocator: std.mem.Allocator) ![]u8 {
                const home = if (config.home_dir.len == 0)
                    try std.process.getEnvVarOwned(allocator, "HOME")
                else
                    try allocator.dupe(u8, config.home_dir);
                defer allocator.free(home);

                const bundle_component = try sanitizePathComponent(allocator, config.bundle_id);
                defer allocator.free(bundle_component);

                return std.fs.path.join(allocator, &.{
                    home,
                    "Library",
                    "Application Support",
                    bundle_component,
                    "storage",
                });
            }

            fn ensureHostPath(path: []const u8) !void {
                if (std.fs.path.isAbsolute(path)) {
                    var root = try std.fs.openDirAbsolute("/", .{});
                    defer root.close();
                    try root.makePath(path[1..]);
                } else {
                    try std.fs.cwd().makePath(path);
                }
            }

            fn resolveStoragePath(root: []const u8, path: []const u8) ![]u8 {
                if (!std.mem.startsWith(u8, path, storage_path)) return error.AccessDenied;
                if (path.len != storage_path.len and path[storage_path.len] != '/') return error.AccessDenied;
                const suffix = if (path.len == storage_path.len) "" else path[storage_path.len + 1 ..];
                if (suffix.len > 0 and suffix[0] == '/') return error.AccessDenied;
                if (hasParentComponent(suffix)) return error.AccessDenied;
                if (suffix.len == 0) return std.heap.page_allocator.dupe(u8, root);
                return std.fs.path.join(std.heap.page_allocator, &.{ root, suffix });
            }

            fn sanitizePathComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
                if (value.len == 0) return allocator.dupe(u8, "default");

                const out = try allocator.alloc(u8, value.len);
                for (value, 0..) |char, i| {
                    out[i] = switch (char) {
                        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => char,
                        else => '_',
                    };
                }
                if (std.mem.eql(u8, out, ".") or std.mem.eql(u8, out, "..")) {
                    allocator.free(out);
                    return allocator.dupe(u8, "default");
                }
                return out;
            }

            fn hasParentComponent(path: []const u8) bool {
                var rest = path;
                while (rest.len > 0) {
                    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
                    if (std.mem.eql(u8, rest[0..slash], "..")) return true;
                    if (slash == rest.len) return false;
                    rest = rest[slash + 1 ..];
                }
                return false;
            }
        };
    };
}

pub const test_runner = struct {
    pub const unit = @import("desktop/test_runner/unit.zig");
};
