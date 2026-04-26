const glib = @import("glib");

pub const backpressure = @import("mixer/backpressure.zig");
pub const close_with_error = @import("mixer/close_with_error.zig");
pub const concurrent_read_write = @import("mixer/concurrent_read_write.zig");
pub const gain_updates = @import("mixer/gain_updates.zig");
pub const hot_path_alloc = @import("mixer/hot_path_alloc.zig");
pub const multi_track_alloc = @import("mixer/multi_track_alloc.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("backpressure", backpressure.make(lib));
            t.run("close_with_error", close_with_error.make(lib));
            t.run("concurrent_read_write", concurrent_read_write.make(lib));
            t.run("gain_updates", gain_updates.make(lib));
            t.run("hot_path_alloc", hot_path_alloc.make(lib));
            t.run("multi_track_alloc", multi_track_alloc.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
