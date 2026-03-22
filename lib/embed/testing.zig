//! Testing utilities — testing helpers with injectable allocator.

const std = @import("std");
const root = @This();

pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectError = std.testing.expectError;

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(std.mem.Allocator, Impl.allocator);
    }

    return struct {
        pub const allocator = Impl.allocator;
        pub const expect = root.expect;
        pub const expectEqual = root.expectEqual;
        pub const expectEqualStrings = root.expectEqualStrings;
        pub const expectError = root.expectError;
    };
}
