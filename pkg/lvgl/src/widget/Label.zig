const binding = @import("../binding.zig");
const embed = @import("embed");
const testing_api = @import("testing");
const Obj = @import("../object/Obj.zig");

const Self = @This();

handle: *binding.Obj,

pub const LongMode = binding.LabelLongMode;
pub const long_mode_wrap: LongMode = binding.LV_LABEL_LONG_MODE_WRAP;
pub const long_mode_dots: LongMode = binding.LV_LABEL_LONG_MODE_DOTS;
pub const long_mode_scroll: LongMode = binding.LV_LABEL_LONG_MODE_SCROLL;
pub const long_mode_scroll_circular: LongMode = binding.LV_LABEL_LONG_MODE_SCROLL_CIRCULAR;
pub const long_mode_clip: LongMode = binding.LV_LABEL_LONG_MODE_CLIP;

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_label_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setText(self: *const Self, new_text: [:0]const u8) void {
    binding.lv_label_set_text(self.handle, new_text.ptr);
}

/// `new_text` is stored by reference; keep it valid until the label text is replaced or the label is deleted.
pub fn setTextStatic(self: *const Self, new_text: [:0]const u8) void {
    binding.lv_label_set_text_static(self.handle, new_text.ptr);
}

pub fn text(self: *const Self) [*:0]const u8 {
    return @ptrCast(binding.lv_label_get_text(self.handle));
}

pub fn setLongMode(self: *const Self, mode: LongMode) void {
    binding.lv_label_set_long_mode(self.handle, mode);
}

pub fn longMode(self: *const Self) LongMode {
    return binding.lv_label_get_long_mode(self.handle);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const lvgl_testing = @import("../testing.zig");
            const mem = lib.mem;

            const Cases = struct {
                fn composesObjectLayerAndStoresText() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setText("hello");

                    try testing.expectEqual(screen.raw(), obj.parent().?.raw());
                    try testing.expectEqualStrings("hello", mem.span(label.text()));
                }

                fn longModeRoundtripsThroughWrapper() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setLongMode(long_mode_scroll);

                    try testing.expectEqual(long_mode_scroll, label.longMode());
                }

                fn staticTextStillParticipatesInObjectApi() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    label.setTextStatic("fixed");

                    obj.setPos(14, 9);
                    obj.updateLayout();

                    try testing.expectEqualStrings("fixed", mem.span(label.text()));
                    try testing.expectEqual(@as(i32, 14), obj.x());
                    try testing.expectEqual(@as(i32, 9), obj.y());
                }

                fn staticTextUsesBorrowedStorage() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var label = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = label.asObj();
                    defer obj.delete();

                    var borrowed = [_:0]u8{ 'v', 'g', 'a', 0 };
                    const borrowed_text = borrowed[0.. :0];
                    label.setTextStatic(borrowed_text);

                    try testing.expectEqual(@intFromPtr(borrowed_text.ptr), @intFromPtr(label.text()));
                }
            };

            Cases.composesObjectLayerAndStoresText() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.longModeRoundtripsThroughWrapper() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.staticTextStillParticipatesInObjectApi() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.staticTextUsesBorrowedStorage() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(runner);
}
