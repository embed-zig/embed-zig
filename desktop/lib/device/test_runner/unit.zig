const glib = @import("glib");
const audio_system = @import("../audio_system.zig");
const bt_host = @import("../bt_host.zig");
const display = @import("../display.zig");
const ledstrip = @import("../ledstrip.zig");
const single_button = @import("../single_button.zig");
const touch = @import("../touch.zig");
const wifi_sta = @import("../wifi_sta.zig");

pub fn make(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("audio_system", audio_system.TestRunner(std));
            t.run("bt_host", bt_host.TestRunner(std));
            t.run("display", display.TestRunner(std));
            t.run("ledstrip", ledstrip.TestRunner(std));
            t.run("single_button", single_button.TestRunner(std));
            t.run("touch", touch.TestRunner(std));
            t.run("wifi_sta", wifi_sta.TestRunner(std));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
