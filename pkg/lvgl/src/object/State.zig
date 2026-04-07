const binding = @import("../binding.zig");
const embed = @import("embed");
const testing_api = @import("testing");

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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Cases = struct {
                fn constantsMatchLvglDefaults() !void {
                    const testing = lib.testing;
                    try testing.expectEqual(@as(Value, 0), default);
                    try testing.expect(pressed != 0);
                    try testing.expect(any > pressed);
                }
            };

            Cases.constantsMatchLvglDefaults() catch |err| {
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
