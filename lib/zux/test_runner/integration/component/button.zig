const testing_api = @import("testing");

pub const single_button = @import("button/single_button.zig");
pub const single_button_long_press = @import("button/single_button_long_press.zig");
pub const grouped_button = @import("button/grouped_button.zig");
pub const grouped_button_long_press = @import("button/grouped_button_long_press.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("single_button", single_button.make(lib, Channel));
            t.run("single_button_long_press", single_button_long_press.make(lib, Channel));
            t.run("grouped_button", grouped_button.make(lib, Channel));
            t.run("grouped_button_long_press", grouped_button_long_press.make(lib, Channel));
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
