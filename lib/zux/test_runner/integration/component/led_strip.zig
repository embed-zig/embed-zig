const testing_api = @import("testing");

pub const animated = @import("led_strip/animated.zig");
pub const flash = @import("led_strip/flash.zig");
pub const pingpong = @import("led_strip/pingpong.zig");
pub const rotate = @import("led_strip/rotate.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("animated", animated.make(lib, Channel));
            t.run("flash", flash.make(lib, Channel));
            t.run("pingpong", pingpong.make(lib, Channel));
            t.run("rotate", rotate.make(lib, Channel));
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
