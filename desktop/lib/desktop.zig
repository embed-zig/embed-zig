const std = @import("std");
const gstd = @import("gstd");

pub const App = @import("desktop/App.zig");
pub const device = @import("device.zig");
pub const http = @import("http.zig");
pub const fs = @import("fs.zig");
pub const log = @import("log.zig");
pub const runtime = gstd.runtime;
pub const PlatformCtx = struct {
    pub const AudioSystem = device.audio_system.AudioSystem;

    pub const fs = struct {
        pub const storage_path = "/storage";
        const bundle_identifier = "dev.embed.desktop.launcher";
        const storage_rel_path = "Library/Application Support/" ++ bundle_identifier ++ "/storage";
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
            std.fs.deleteFileAbsolute(host_path) catch |err| switch (err) {
                error.IsDir => return std.fs.deleteTreeAbsolute(host_path),
                error.FileNotFound => return,
                else => return err,
            };
        }

        fn ensureHostStorageRoot() ![]const u8 {
            if (host_storage_root) |root| return root;

            const allocator = std.heap.page_allocator;
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);

            var home_dir = try std.fs.openDirAbsolute(home, .{});
            defer home_dir.close();
            try home_dir.makePath(storage_rel_path);

            const root = try std.fs.path.join(allocator, &.{ home, storage_rel_path });
            host_storage_root = root;
            return root;
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
pub const test_runner = struct {
    pub const unit = @import("desktop/test_runner/unit.zig");
};
