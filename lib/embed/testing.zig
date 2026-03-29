//! Testing utilities — thin testing facade for an injected implementation.

const mem = @import("mem.zig");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(mem.Allocator, Impl.allocator);
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

test "embed/unit_tests/testing/make_exposes_impl_symbols" {
    const std = @import("std");
    const testing = make(std.testing);

    try testing.expect(true);
    const bytes = try testing.allocator.dupe(u8, "test");
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 4), bytes.len);
}
