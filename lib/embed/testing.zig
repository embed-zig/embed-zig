//! Testing utilities — testing helpers with injectable allocator.

const std = @import("std_re_export.zig");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(std.mem.Allocator, Impl.allocator);
        _ = Impl.expect;
        _ = Impl.expectEqual;
        _ = Impl.expectEqualSlices;
        _ = Impl.expectEqualStrings;
        _ = Impl.expectError;
    }

    return struct {
        pub const allocator = Impl.allocator;
        pub const expect = Impl.expect;
        pub const expectEqual = Impl.expectEqual;
        pub const expectEqualSlices = Impl.expectEqualSlices;
        pub const expectEqualStrings = Impl.expectEqualStrings;
        pub const expectError = Impl.expectError;
    };
}
