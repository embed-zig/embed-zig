//! testing — Go-style testing helpers built on an injected runtime.
const root = @This();

pub const T = @import("testing/T.zig");
pub const TestingAllocator = @import("testing/TestingAllocator.zig");
pub const CountingAllocator = root.TestingAllocator;
pub const LimitAllocator = root.TestingAllocator;
pub const TestRunner = @import("testing/TestRunner.zig");

test "testing/unit_tests" {
    _ = @import("testing/T.zig");
    _ = @import("testing/TestingAllocator.zig");
}
