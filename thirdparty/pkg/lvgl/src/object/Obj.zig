const glib = @import("glib");
const binding = @import("../binding.zig");
const embed = @import("embed");
const Color = @import("../Color.zig");
const Style = @import("../Style.zig");
const types = @import("../types.zig");
const Event = @import("../Event.zig");
const Flags = @import("Flags.zig");
const State = @import("State.zig");
const Tree = @import("Tree.zig");

const Self = @This();

handle: *binding.Obj,

pub const Selector = binding.StyleSelector;

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn create(parent_obj: ?*const Self) ?Self {
    const parent_handle = if (parent_obj) |p| p.handle else null;
    const handle = binding.lv_obj_create(parent_handle) orelse return null;
    return fromRaw(handle);
}

pub fn screenActive() ?Self {
    const handle = binding.lv_screen_active() orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn delete(self: *Self) void {
    binding.lv_obj_delete(self.handle);
}

pub fn clean(self: *const Self) void {
    binding.lv_obj_clean(self.handle);
}

pub fn parent(self: *const Self) ?Self {
    const handle = Tree.parentRaw(self.handle) orelse return null;
    return fromRaw(handle);
}

pub fn screen(self: *const Self) Self {
    return fromRaw(Tree.screenRaw(self.handle) orelse {
        @panic("LVGL object did not resolve to a screen");
    });
}

pub fn child(self: *const Self, index: i32) ?Self {
    const handle = Tree.childRaw(self.handle, index) orelse return null;
    return fromRaw(handle);
}

pub fn childCount(self: *const Self) u32 {
    return Tree.childCount(self.handle);
}

pub fn setParent(self: *const Self, parent_obj: *const Self) void {
    binding.lv_obj_set_parent(self.handle, parent_obj.handle);
}

pub fn setPos(self: *const Self, new_x: i32, new_y: i32) void {
    binding.lv_obj_set_pos(self.handle, new_x, new_y);
}

pub fn setX(self: *const Self, new_x: i32) void {
    binding.lv_obj_set_x(self.handle, new_x);
}

pub fn setY(self: *const Self, new_y: i32) void {
    binding.lv_obj_set_y(self.handle, new_y);
}

pub fn setSize(self: *const Self, new_width: i32, new_height: i32) void {
    binding.lv_obj_set_size(self.handle, new_width, new_height);
}

pub fn setWidth(self: *const Self, new_width: i32) void {
    binding.lv_obj_set_width(self.handle, new_width);
}

pub fn setHeight(self: *const Self, new_height: i32) void {
    binding.lv_obj_set_height(self.handle, new_height);
}

pub fn alignTo(self: *const Self, alignment: types.Align, x_offset: i32, y_offset: i32) void {
    binding.lv_obj_align(self.handle, @as(binding.Align, @intCast(@intFromEnum(alignment))), x_offset, y_offset);
}

pub fn center(self: *const Self) void {
    binding.lv_obj_center(self.handle);
}

pub fn updateLayout(self: *const Self) void {
    binding.lv_obj_update_layout(self.handle);
}

pub fn x(self: *const Self) i32 {
    return binding.lv_obj_get_x(self.handle);
}

pub fn y(self: *const Self) i32 {
    return binding.lv_obj_get_y(self.handle);
}

pub fn width(self: *const Self) i32 {
    return binding.lv_obj_get_width(self.handle);
}

pub fn height(self: *const Self) i32 {
    return binding.lv_obj_get_height(self.handle);
}

pub fn addFlag(self: *const Self, flag: Flags.Value) void {
    binding.lv_obj_add_flag(self.handle, Flags.toRaw(flag));
}

pub fn removeFlag(self: *const Self, flag: Flags.Value) void {
    binding.lv_obj_remove_flag(self.handle, Flags.toRaw(flag));
}

pub fn setFlag(self: *const Self, flag: Flags.Value, enabled: bool) void {
    binding.lv_obj_set_flag(self.handle, Flags.toRaw(flag), enabled);
}

pub fn hasFlag(self: *const Self, flag: Flags.Value) bool {
    return binding.lv_obj_has_flag(self.handle, Flags.toRaw(flag));
}

pub fn hasAnyFlag(self: *const Self, flag: Flags.Value) bool {
    return binding.lv_obj_has_flag_any(self.handle, Flags.toRaw(flag));
}

pub fn addState(self: *const Self, new_state: State.Value) void {
    binding.lv_obj_add_state(self.handle, State.toRaw(new_state));
}

pub fn removeState(self: *const Self, old_state: State.Value) void {
    binding.lv_obj_remove_state(self.handle, State.toRaw(old_state));
}

pub fn setState(self: *const Self, next_state: State.Value, enabled: bool) void {
    binding.lv_obj_set_state(self.handle, State.toRaw(next_state), enabled);
}

pub fn hasState(self: *const Self, queried_state: State.Value) bool {
    return binding.lv_obj_has_state(self.handle, State.toRaw(queried_state));
}

pub fn state(self: *const Self) binding.State {
    return binding.lv_obj_get_state(self.handle);
}

pub fn addStyle(self: *const Self, style: *const Style, selector: Selector) void {
    binding.lv_obj_add_style(self.handle, style.rawConstPtr(), selector);
}

pub fn removeStyle(self: *const Self, style: *const Style, selector: Selector) void {
    binding.lv_obj_remove_style(self.handle, style.rawConstPtr(), selector);
}

pub fn removeStyleAll(self: *const Self) void {
    binding.lv_obj_remove_style_all(self.handle);
}

pub fn setStyleBgColor(self: *const Self, color: Color, selector: Selector) void {
    binding.embed_lv_obj_set_style_bg_color_rgb(self.handle, color.red, color.green, color.blue, selector);
}

pub fn setStyleBgOpa(self: *const Self, opa: types.Opa, selector: Selector) void {
    binding.lv_obj_set_style_bg_opa(self.handle, opa, selector);
}

pub fn setStyleBorderWidth(self: *const Self, width_value: i32, selector: Selector) void {
    binding.lv_obj_set_style_border_width(self.handle, width_value, selector);
}

pub fn setStyleOutlineWidth(self: *const Self, width_value: i32, selector: Selector) void {
    binding.lv_obj_set_style_outline_width(self.handle, width_value, selector);
}

pub fn setStylePadAll(self: *const Self, value: i32, selector: Selector) void {
    binding.lv_obj_set_style_pad_all(self.handle, value, selector);
}

pub fn setStylePadHor(self: *const Self, value: i32, selector: Selector) void {
    binding.lv_obj_set_style_pad_hor(self.handle, value, selector);
}

pub fn setStylePadVer(self: *const Self, value: i32, selector: Selector) void {
    binding.lv_obj_set_style_pad_ver(self.handle, value, selector);
}

pub fn setStyleRadius(self: *const Self, radius: i32, selector: Selector) void {
    binding.lv_obj_set_style_radius(self.handle, radius, selector);
}

pub fn setStyleTextColor(self: *const Self, color: Color, selector: Selector) void {
    binding.embed_lv_obj_set_style_text_color_rgb(self.handle, color.red, color.green, color.blue, selector);
}

pub fn hasStyleProp(self: *const Self, selector: Selector, prop: binding.StyleProp) bool {
    return binding.lv_obj_has_style_prop(self.handle, selector, prop);
}

pub fn addEventCallbackRaw(
    self: *const Self,
    callback: binding.EventCallback,
    filter: binding.EventCode,
    user_data: ?*anyopaque,
) void {
    _ = binding.lv_obj_add_event_cb(self.handle, callback, filter, user_data);
}

pub fn eventCount(self: *const Self) u32 {
    return @intCast(binding.lv_obj_get_event_count(self.handle));
}

pub fn sendEvent(
    self: *const Self,
    event_code: binding.EventCode,
    param: ?*anyopaque,
) binding.Result {
    return binding.lv_obj_send_event(self.handle, event_code, param);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const lvgl_testing = @import("../testing.zig");

            const Cases = struct {
                fn geometrySettersRoundtripAfterLayoutUpdate() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var root_screen = fixture.screen();
                    var obj = Self.create(&root_screen) orelse return error.OutOfMemory;
                    defer obj.delete();

                    obj.setPos(11, 22);
                    obj.setSize(33, 44);
                    obj.alignTo(.top_left, 11, 22);
                    obj.center();
                    obj.updateLayout();

                    try grt.std.testing.expectEqual(@as(i32, 33), obj.width());
                    try grt.std.testing.expectEqual(@as(i32, 44), obj.height());
                }

                fn flagsStateAndStylesUpdateThroughObjectApi() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var root_screen = fixture.screen();
                    var obj = Self.create(&root_screen) orelse return error.OutOfMemory;
                    defer obj.delete();

                    try grt.std.testing.expect(!obj.hasFlag(Flags.hidden));
                    obj.addFlag(Flags.hidden);
                    try grt.std.testing.expect(obj.hasFlag(Flags.hidden));
                    obj.removeFlag(Flags.hidden);
                    try grt.std.testing.expect(!obj.hasFlag(Flags.hidden));

                    try grt.std.testing.expect(!obj.hasState(State.pressed));
                    obj.addState(State.pressed);
                    try grt.std.testing.expect(obj.hasState(State.pressed));
                    obj.removeState(State.pressed);
                    try grt.std.testing.expect(!obj.hasState(State.pressed));

                    var style = Style.init();
                    defer style.deinit();
                    style.setWidth(77);

                    obj.setWidth(25);
                    obj.updateLayout();
                    try grt.std.testing.expectEqual(@as(i32, 25), obj.width());

                    obj.addStyle(&style, State.user_4);
                    obj.addState(State.user_4);
                    binding.lv_obj_refresh_style(obj.raw(), binding.LV_PART_MAIN, Style.width_prop);
                    try grt.std.testing.expectEqual(
                        @as(i32, 77),
                        binding.lv_obj_get_style_prop(obj.raw(), binding.LV_PART_MAIN, Style.width_prop).num,
                    );

                    obj.removeStyle(&style, State.user_4);
                    binding.lv_obj_refresh_style(obj.raw(), binding.LV_PART_MAIN, Style.width_prop);
                    try grt.std.testing.expectEqual(
                        @as(i32, 25),
                        binding.lv_obj_get_style_prop(obj.raw(), binding.LV_PART_MAIN, Style.width_prop).num,
                    );
                }

                fn rawEventCallbackReceivesTargetPayloadAndUserData() !void {
                    const CallbackCtx = struct {
                        calls: usize = 0,
                        target: ?*binding.Obj = null,
                        param: ?*anyopaque = null,
                        user_data: ?*anyopaque = null,

                        fn callback(event: ?*binding.Event) callconv(.c) void {
                            const Context = @This();
                            const e = event orelse return;
                            const user_data = binding.lv_event_get_user_data(e) orelse return;
                            const ctx: *Context = @ptrCast(@alignCast(user_data));
                            ctx.calls += 1;
                            ctx.target = binding.lv_event_get_target_obj(e);
                            ctx.param = binding.lv_event_get_param(e);
                            ctx.user_data = user_data;
                        }
                    };

                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var root_screen = fixture.screen();
                    var obj = Self.create(&root_screen) orelse return error.OutOfMemory;
                    defer obj.delete();

                    var ctx = CallbackCtx{};
                    var payload: u32 = 0xBEEF;
                    const custom_event = Event.codeFromInt(Event.registerId());

                    obj.addEventCallbackRaw(CallbackCtx.callback, custom_event, &ctx);
                    try grt.std.testing.expectEqual(@as(u32, 1), obj.eventCount());

                    _ = obj.sendEvent(custom_event, &payload);

                    try grt.std.testing.expectEqual(@as(usize, 1), ctx.calls);
                    try grt.std.testing.expectEqual(obj.raw(), ctx.target.?);
                    try grt.std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&payload)), ctx.param);
                    try grt.std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&ctx)), ctx.user_data);
                }
            };

            Cases.geometrySettersRoundtripAfterLayoutUpdate() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.flagsStateAndStylesUpdateThroughObjectApi() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.rawEventCallbackReceivesTargetPayloadAndUserData() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
