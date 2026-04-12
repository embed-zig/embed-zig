const testing_api = @import("testing");

pub const flow = @import("ui/flow.zig");
pub const overlay = @import("ui/overlay.zig");
pub const selection = @import("ui/selection.zig");
pub const route = @import("ui/route.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("flow", flow.make(lib, Channel));
            t.run("overlay", overlay.make(lib, Channel));
            t.run("selection", selection.make(lib, Channel));
            t.run("route", route.make(lib, Channel));
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
