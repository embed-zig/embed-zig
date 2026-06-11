const glib = @import("glib");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");
const TextArea = @import("TextArea.zig");

const Self = @This();

handle: *binding.Obj,

pub const Mode = binding.KeyboardMode;
pub const text_lower: Mode = binding.LV_KEYBOARD_MODE_TEXT_LOWER;
pub const text_upper: Mode = binding.LV_KEYBOARD_MODE_TEXT_UPPER;
pub const special: Mode = binding.LV_KEYBOARD_MODE_SPECIAL;
pub const number: Mode = binding.LV_KEYBOARD_MODE_NUMBER;
pub const Ctrl = binding.ButtonMatrixCtrl;
pub const ctrl_width_1: Ctrl = binding.LV_BUTTONMATRIX_CTRL_WIDTH_1;
pub const ctrl_click_trig: Ctrl = binding.LV_BUTTONMATRIX_CTRL_CLICK_TRIG;
pub const ctrl_checked: Ctrl = binding.LV_BUTTONMATRIX_CTRL_CHECKED;
pub const button_none: u32 = binding.LV_BUTTONMATRIX_BUTTON_NONE;
pub const MapText = [*:0]const u8;

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_keyboard_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setTextArea(self: *const Self, textarea: ?*const TextArea) void {
    binding.lv_keyboard_set_textarea(self.handle, if (textarea) |ta| ta.raw() else null);
}

pub fn setMode(self: *const Self, new_mode: Mode) void {
    binding.lv_keyboard_set_mode(self.handle, new_mode);
}

pub fn mode(self: *const Self) Mode {
    return binding.lv_keyboard_get_mode(self.handle);
}

pub fn setPopovers(self: *const Self, enabled: bool) void {
    binding.lv_keyboard_set_popovers(self.handle, enabled);
}

pub fn setMap(self: *const Self, target_mode: Mode, map: []const MapText, ctrl_map: []const Ctrl) void {
    binding.lv_keyboard_set_map(self.handle, target_mode, @ptrCast(map.ptr), @ptrCast(ctrl_map.ptr));
}

pub fn setSelectedButton(self: *const Self, button_id: u32) void {
    binding.lv_buttonmatrix_set_selected_button(self.handle, button_id);
}

pub fn selectedButton(self: *const Self) u32 {
    return binding.lv_buttonmatrix_get_selected_button(self.handle);
}

pub fn buttonText(self: *const Self, button_id: u32) [*:0]const u8 {
    return @ptrCast(binding.lv_keyboard_get_button_text(self.handle, button_id));
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
                fn composesWithTextAreaAndRoundtripsMode() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var textarea = TextArea.create(&screen) orelse return error.OutOfMemory;
                    var textarea_obj = textarea.asObj();
                    defer textarea_obj.delete();

                    var keyboard = Self.create(&screen) orelse return error.OutOfMemory;
                    var keyboard_obj = keyboard.asObj();
                    defer keyboard_obj.delete();

                    keyboard.setTextArea(&textarea);
                    keyboard.setMode(number);
                    keyboard.setPopovers(false);
                    keyboard.setSelectedButton(0);

                    try grt.std.testing.expectEqual(screen.raw(), keyboard_obj.parent().?.raw());
                    try grt.std.testing.expectEqual(number, keyboard.mode());
                    try grt.std.testing.expectEqual(@as(u32, 0), keyboard.selectedButton());
                }
            };

            Cases.composesWithTextAreaAndRoundtripsMode() catch |err| {
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
