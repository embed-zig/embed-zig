//! LVGL API smoke integration runner (`integration/lvgl/*` case runners).

const glib = @import("glib");
const embed = @import("embed");
const anim = @import("lvgl/anim.zig");
const basic = @import("lvgl/basic.zig");
const label = @import("lvgl/label.zig");
const button = @import("lvgl/button.zig");
const os = @import("lvgl/os.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("basic", basic.make(grt));
            t.run("label", label.make(grt));
            t.run("button", button.make(grt));
            t.run("anim", anim.make(grt));
            t.run("os", os.make(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
