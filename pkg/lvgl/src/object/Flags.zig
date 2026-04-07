const binding = @import("../binding.zig");
const embed = @import("embed");
const testing_api = @import("testing");

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
                fn constantsExposeExpectedBitMasks() !void {
                    const testing = lib.testing;
                    try testing.expect(hidden != 0);
                    try testing.expect(clickable != 0);
                    try testing.expect((event_bubble & event_trickle) == 0);
                }
            };

            Cases.constantsExposeExpectedBitMasks() catch |err| {
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
