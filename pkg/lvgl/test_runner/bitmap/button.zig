const embed = @import("embed");
const testing = @import("testing");
const Display = @import("../Display.zig");
const Fixture = @import("../display/Fixture.zig");
const lvgl = @import("../../../lvgl.zig");

pub const DrawSpec = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const button_x: i32 = 8;
pub const button_y: i32 = 10;
pub const button_w: i32 = 28;
pub const button_h: i32 = 14;

pub fn drawSpec(display: *const Display) DrawSpec {
    return .{
        .x = 0,
        .y = 0,
        .w = display.width(),
        .h = display.height(),
    };
}

pub fn make(comptime lib: type, display: *Display) testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;

            var fixture = Fixture.init(self.display) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer fixture.deinit();

            fixture.render() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            var screen = fixture.screen();
            var button = lvgl.Button.create(&screen) orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            var button_obj = button.asObj();
            defer button_obj.delete();

            button_obj.setPos(button_x, button_y);
            button_obj.setSize(button_w, button_h);
            button_obj.updateLayout();

            var label = button.createLabel() orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            label.setText("OK");
            button_obj.updateLayout();

            fixture.render() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .display = display,
    };
    return testing.TestRunner.make(Runner).new(runner);
}
