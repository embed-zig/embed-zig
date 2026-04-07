const binding = @import("../binding.zig");
const embed = @import("embed");
const testing_api = @import("testing");
const Obj = @import("../object/Obj.zig");
const Flags = @import("../object/Flags.zig");
const Label = @import("Label.zig");

const Self = @This();

handle: *binding.Obj,

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_button_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn createLabel(self: *const Self) ?Label {
    const obj = self.asObj();
    return Label.create(&obj);
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
                fn composesObjectLayerAndCanHostChildLabel() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = Self.create(&screen) orelse return error.OutOfMemory;
                    var button_obj = button.asObj();
                    defer button_obj.delete();

                    var label = button.createLabel() orelse return error.OutOfMemory;
                    label.setText("press");

                    try testing.expectEqual(screen.raw(), button_obj.parent().?.raw());
                    try testing.expectEqual(@as(u32, 1), button_obj.childCount());
                    try testing.expectEqual(button_obj.raw(), label.asObj().parent().?.raw());
                    try testing.expectEqualStrings("press", mem.span(label.text()));
                }

                fn objectApiRemainsTheSourceOfGenericBehavior() !void {
                    const testing = lib.testing;
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var button = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = button.asObj();
                    defer obj.delete();

                    obj.setPos(21, 13);
                    obj.setSize(80, 32);
                    obj.addFlag(Flags.clickable);
                    obj.updateLayout();

                    try testing.expectEqual(@as(i32, 21), obj.x());
                    try testing.expectEqual(@as(i32, 13), obj.y());
                    try testing.expectEqual(@as(i32, 80), obj.width());
                    try testing.expectEqual(@as(i32, 32), obj.height());
                    try testing.expect(obj.hasFlag(Flags.clickable));
                }

                fn rawAndObjectRoundtripPreserveHandle() !void {
                    const testing = lib.testing;

                    const raw_handle: *binding.Obj = @ptrFromInt(1);
                    const button = Self.fromRaw(raw_handle);

                    try testing.expectEqual(raw_handle, button.raw());
                    try testing.expectEqual(raw_handle, button.asObj().raw());
                }
            };

            Cases.composesObjectLayerAndCanHostChildLabel() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.objectApiRemainsTheSourceOfGenericBehavior() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.rawAndObjectRoundtripPreserveHandle() catch |err| {
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
