//! testing — Go-style testing helpers built on an injected runtime.
const root = @This();

pub const std = @import("testing/std.zig");
pub const T = @import("testing/T.zig");
pub const IsolationThread = @import("testing/IsolationThread.zig");
pub const TestingAllocator = @import("testing/TestingAllocator.zig");
pub const CountingAllocator = root.TestingAllocator;
pub const LimitAllocator = root.TestingAllocator;
pub const TestRunner = @import("testing/TestRunner.zig");
pub const test_runner = struct {
    pub const unit = @import("testing/test_runner/unit.zig");
};
