const embed = @import("embed");
const display_api = @import("display");
const testing = @import("testing");
const Display = display_api.Display;
const Fixture = @import("test_utils/Fixture.zig");
const lvgl = @import("../../../../lvgl.zig");

const Tick = lvgl.Tick;
const Anim = lvgl.Anim;

pub const button_y: i32 = 10;
pub const button_w: i32 = 28;
pub const button_h: i32 = 14;
pub const button_start_x: i32 = 4;
pub const button_end_x: i32 = 24;

const AnimState = struct {
    obj: lvgl.Obj,
};

pub fn make(comptime lib: type, display: *Display) testing.TestRunner {
    const Runner = struct {
        display: *Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            const test_lib = lib.testing;

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

            button_obj.setPos(button_start_x, button_y);
            button_obj.setSize(button_w, button_h);
            button_obj.updateLayout();

            var label = button.createLabel() orelse {
                t.logFatal(@errorName(error.OutOfMemory));
                return false;
            };
            label.setText("GO");
            button_obj.updateLayout();

            fixture.render() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            var state = AnimState{ .obj = button_obj };
            var anim = Anim.init() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer anim.deinit();

            anim.setVar(&state);
            anim.setExecCb(animExecMoveButtonX);
            anim.setDuration(40);
            anim.setValues(button_start_x, button_end_x);
            anim.setRepeatCount(1);

            _ = anim.start();

            var i: u32 = 0;
            while (button_obj.x() < button_end_x and i < 32) : (i += 1) {
                Tick.inc(10);
                _ = Tick.timerHandler();
            }

            button_obj.updateLayout();
            test_lib.expectEqual(button_end_x, button_obj.x()) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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

fn animExecMoveButtonX(var_: ?*anyopaque, value: i32) callconv(.c) void {
    const state: *AnimState = @ptrCast(@alignCast(var_.?));
    state.obj.setX(value);
}
