const glib = @import("glib");
const binding = @import("../binding.zig");
const embed = @import("embed");

pub const Value = u32;

pub const hidden: Value = @intCast(binding.LV_OBJ_FLAG_HIDDEN);
pub const clickable: Value = @intCast(binding.LV_OBJ_FLAG_CLICKABLE);
pub const scrollable: Value = @intCast(binding.LV_OBJ_FLAG_SCROLLABLE);
pub const event_bubble: Value = @intCast(binding.LV_OBJ_FLAG_EVENT_BUBBLE);
pub const event_trickle: Value = @intCast(binding.LV_OBJ_FLAG_EVENT_TRICKLE);

pub fn toRaw(value: Value) binding.ObjFlag {
    return switch (@typeInfo(binding.ObjFlag)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.ObjFlag, @intCast(value)),
    };
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

            const Cases = struct {
                fn constantsExposeExpectedBitMasks() !void {
                    try grt.std.testing.expect(hidden != 0);
                    try grt.std.testing.expect(clickable != 0);
                    try grt.std.testing.expect((event_bubble & event_trickle) == 0);
                }
            };

            Cases.constantsExposeExpectedBitMasks() catch |err| {
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
