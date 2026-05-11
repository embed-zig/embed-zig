//! encoding — byte-to-text codecs.
//!
//! Mirrors Go-style encoding packages at the glib namespace level. The package
//! owns codecs that are not part of the runtime `stdz` contract.

pub const base64 = @import("encoding/base64.zig");
pub const base32 = @import("encoding/base32.zig");
pub const base58 = @import("encoding/base58.zig");

pub const base58btc = base58.btc;
pub const base32crockford = base32.crockford;

pub const test_runner = struct {
    pub const unit = @import("encoding/test_runner/unit.zig");
};
