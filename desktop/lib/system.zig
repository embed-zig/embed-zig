const glib = @import("glib");

pub const Preferences = @import("embed").system.Preferences;
pub const preferences = @import("system/preferences.zig");

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            const Runner = struct {
                pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
                    _ = self;
                    t.run("preferences", preferences.TestRunner(grt));
                    _ = allocator;
                    return t.wait();
                }

                pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
                    _ = self;
                    _ = allocator;
                }
            };

            const Holder = struct {
                var runner: Runner = .{};
            };
            return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
        }
    };
};
