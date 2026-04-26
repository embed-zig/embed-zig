//! `audio/ogg/types.zig` defines the shared type and allocator baseline for the
//! pure Zig Ogg rewrite.

const glib = @import("glib");

pub const CastError = error{
    NegativeValue,
    Overflow,
};

pub fn usizeToIsize(value: usize) CastError!isize {
    if (value > maxIsizeAsUsize()) return error.Overflow;
    return @intCast(value);
}

pub fn isizeToUsize(value: isize) CastError!usize {
    if (value < 0) return error.NegativeValue;
    return @intCast(value);
}

pub fn int32ToUsize(value: i32) CastError!usize {
    if (value < 0) return error.NegativeValue;
    return @intCast(value);
}

pub fn usizeToInt32(value: usize) CastError!i32 {
    if (value > maxInt32AsUsize()) return error.Overflow;
    return @intCast(value);
}

pub fn boolToInt32(value: bool) i32 {
    return @intFromBool(value);
}

fn maxIsizeAsUsize() usize {
    const bits = @typeInfo(isize).int.bits;
    return (@as(usize, 1) << (bits - 1)) - 1;
}

fn maxInt32AsUsize() usize {
    return (@as(usize, 1) << (@bitSizeOf(i32) - 1)) - 1;
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn testIntegerCastsPreserveValidValues() !void {
            const testing = lib.testing;

            try testing.expectEqual(@as(isize, 12), try usizeToIsize(12));
            try testing.expectEqual(@as(usize, 7), try isizeToUsize(7));
            try testing.expectEqual(@as(usize, 5), try int32ToUsize(5));
            try testing.expectEqual(@as(i32, 9), try usizeToInt32(9));
        }

        fn testIntegerCastsRejectNegativeValues() !void {
            const testing = lib.testing;

            try testing.expectError(error.NegativeValue, isizeToUsize(-1));
            try testing.expectError(error.NegativeValue, int32ToUsize(-1));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testIntegerCastsPreserveValidValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testIntegerCastsRejectNegativeValues() catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
