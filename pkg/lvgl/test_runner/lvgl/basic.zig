//! lvgl basic test runner — runtime and object smoke tests.
//!
//! Usage:
//!   const runner = @import("lvgl/test_runner/lvgl/basic.zig").make(std);

const embed = @import("embed");
const testing = @import("testing");
const lvgl = @import("../../../lvgl.zig");
const common = @import("common.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const test_lib = lib.testing;

            const Cases = struct {
                fn bootstrapAndDefaultScreen() !void {
                    var fixture = try common.Fixture.init();
                    defer fixture.deinit();

                    try test_lib.expect(lvgl.isInitialized());
                    try test_lib.expectEqual(@as(i32, 320), fixture.display.width());
                    try test_lib.expectEqual(@as(i32, 240), fixture.display.height());

                    const default_display = lvgl.Display.getDefault() orelse return error.ExpectedDefaultDisplay;
                    try test_lib.expectEqual(fixture.display.raw(), default_display.raw());

                    const screen = fixture.screen();
                    try test_lib.expect(screen.parent() == null);
                    try test_lib.expectEqual(screen.raw(), fixture.display.activeScreen().raw());
                }

                fn objectEventFlowSmoke() !void {
                    const CallbackState = struct {
                        calls: usize = 0,
                        target: ?*lvgl.binding.Obj = null,
                        current_target: ?*lvgl.binding.Obj = null,
                        param: ?*anyopaque = null,
                        user_data: ?*anyopaque = null,

                        fn callback(event: ?*lvgl.binding.Event) callconv(.c) void {
                            const State = @This();
                            const e = event orelse return;
                            const user_data = lvgl.binding.lv_event_get_user_data(e) orelse return;
                            const state_ptr: *State = @ptrCast(@alignCast(user_data));
                            state_ptr.calls += 1;
                            state_ptr.target = lvgl.binding.lv_event_get_target_obj(e);
                            state_ptr.current_target = lvgl.binding.lv_event_get_current_target_obj(e);
                            state_ptr.param = lvgl.binding.lv_event_get_param(e);
                            state_ptr.user_data = user_data;
                        }
                    };

                    var fixture = try common.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var obj = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
                    defer obj.delete();

                    var state = CallbackState{};
                    var payload: u32 = 0xCAFE;
                    const custom_event = lvgl.Event.codeFromInt(lvgl.Event.registerId());

                    obj.addEventCallbackRaw(CallbackState.callback, custom_event, &state);
                    try test_lib.expectEqual(@as(u32, 1), obj.eventCount());

                    const result = obj.sendEvent(custom_event, &payload);
                    try test_lib.expectEqual(
                        @as(c_uint, @intCast(@intFromEnum(lvgl.Result.ok))),
                        @as(c_uint, @intCast(result)),
                    );
                    try test_lib.expectEqual(@as(usize, 1), state.calls);
                    try test_lib.expectEqual(obj.raw(), state.target.?);
                    try test_lib.expectEqual(obj.raw(), state.current_target.?);
                    try test_lib.expectEqual(@as(?*anyopaque, @ptrCast(&payload)), state.param);
                    try test_lib.expectEqual(@as(?*anyopaque, @ptrCast(&state)), state.user_data);
                }
            };

            Cases.bootstrapAndDefaultScreen() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.objectEventFlowSmoke() catch |err| {
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
    runner.* = .{};
    return testing.TestRunner.make(Runner).new(runner);
}
