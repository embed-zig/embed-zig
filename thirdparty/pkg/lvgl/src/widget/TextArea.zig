const glib = @import("glib");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");

const Self = @This();

handle: *binding.Obj,

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_textarea_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setText(self: *const Self, new_text: [:0]const u8) void {
    binding.lv_textarea_set_text(self.handle, new_text.ptr);
}

pub fn text(self: *const Self) [*:0]const u8 {
    return @ptrCast(binding.lv_textarea_get_text(self.handle));
}

pub fn addChar(self: *const Self, char: u32) void {
    binding.lv_textarea_add_char(self.handle, char);
}

pub fn deleteChar(self: *const Self) void {
    binding.lv_textarea_delete_char(self.handle);
}

pub fn setOneLine(self: *const Self, enabled: bool) void {
    binding.lv_textarea_set_one_line(self.handle, enabled);
}

pub fn setPasswordMode(self: *const Self, enabled: bool) void {
    binding.lv_textarea_set_password_mode(self.handle, enabled);
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
            const mem = grt.std.mem;

            const Cases = struct {
                fn storesTextAndComposesObjectLayer() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var textarea = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = textarea.asObj();
                    defer obj.delete();

                    textarea.setText("secret");

                    try grt.std.testing.expectEqual(screen.raw(), obj.parent().?.raw());
                    try grt.std.testing.expectEqualStrings("secret", mem.span(textarea.text()));
                }
            };

            Cases.storesTextAndComposesObjectLayer() catch |err| {
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
