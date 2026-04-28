//! glib crypto algorithms.
//!
//! This namespace contains crypto implementations owned by glib. It is separate
//! from `stdz.crypto`, which remains the runtime compatibility contract.

pub const x25519 = @import("crypto/x25519.zig");

pub const test_runner = struct {
    pub const unit = @import("crypto/test_runner/unit.zig");
};
