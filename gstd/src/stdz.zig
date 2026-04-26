//! Std-backed implementation of stdz contracts.

const builtin = @import("builtin");

pub const Thread = @import("stdz/Thread.zig");
pub const atomic = @import("stdz/atomic.zig");
pub const heap = @import("stdz/heap.zig");
pub const log = @import("stdz/log.zig");
pub const testing = @import("stdz/testing.zig");
pub const posix = if (builtin.target.os.tag == .windows)
    void
else
    @import("stdz/posix.zig");
pub const time = @import("stdz/time.zig");
pub const crypto = @import("stdz/crypto.zig");
