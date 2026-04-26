const Context = @This();
const glib = @import("glib");

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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn castReturnsTypedPointer() !void {
            var value: u32 = 7;
            const ctx: Type = @ptrCast(&value);
            const casted = cast(u32, ctx).?;

            try grt.std.testing.expectEqual(@as(u32, 7), casted.*);
        }

        fn castNullReturnsNull() !void {
            try grt.std.testing.expect(cast(u32, null) == null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.castReturnsTypedPointer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.castNullReturnsNull() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
