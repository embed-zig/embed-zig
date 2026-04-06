const Context = @This();
const testing_api = @import("testing");

pub const Type = ?*anyopaque;

/// Caller contract:
/// - `ctx` must have originally been created from a pointer to `T`
/// - the pointer must satisfy `T`'s alignment
/// This helper only performs the nullable cast boundary; it does not provide
/// runtime type checking for `anyopaque`.
pub fn cast(comptime T: type, ctx: Type) ?*T {
    const ptr = ctx orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn castReturnsTypedPointer(testing: anytype) !void {
            var value: u32 = 7;
            const ctx: Type = @ptrCast(&value);
            const casted = cast(u32, ctx).?;

            try testing.expectEqual(@as(u32, 7), casted.*);
        }

        fn castNullReturnsNull(testing: anytype) !void {
            try testing.expect(cast(u32, null) == null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.castReturnsTypedPointer(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.castNullReturnsNull(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
