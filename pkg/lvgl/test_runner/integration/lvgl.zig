//! LVGL API smoke integration runner (`integration/lvgl/*` case runners).

const embed = @import("embed");
const testing = @import("testing");
const anim = @import("lvgl/anim.zig");
const basic = @import("lvgl/basic.zig");
const label = @import("lvgl/label.zig");
const button = @import("lvgl/button.zig");
const os = @import("lvgl/os.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("basic", basic.make(lib));
            t.run("label", label.make(lib));
            t.run("button", button.make(lib));
            t.run("anim", anim.make(lib));
            t.run("os", os.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing.TestRunner.make(Runner).new(runner);
}
