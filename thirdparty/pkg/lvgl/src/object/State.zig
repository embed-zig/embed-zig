const glib = @import("glib");
const binding = @import("../binding.zig");
const embed = @import("embed");

pub const Value = u32;

pub const default: Value = @intCast(binding.LV_STATE_DEFAULT);
pub const pressed: Value = @intCast(binding.LV_STATE_PRESSED);
pub const focused: Value = @intCast(binding.LV_STATE_FOCUSED);
pub const disabled: Value = @intCast(binding.LV_STATE_DISABLED);
pub const checked: Value = @intCast(binding.LV_STATE_CHECKED);
pub const user_4: Value = @intCast(binding.LV_STATE_USER_4);
pub const any: Value = @intCast(binding.LV_STATE_ANY);

pub fn toRaw(value: Value) binding.State {
    return switch (@typeInfo(binding.State)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.State, @intCast(value)),
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
                fn constantsMatchLvglDefaults() !void {
                    try grt.std.testing.expectEqual(@as(Value, 0), default);
                    try grt.std.testing.expect(pressed != 0);
                    try grt.std.testing.expect(any > pressed);
                }
            };

            Cases.constantsMatchLvglDefaults() catch |err| {
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
