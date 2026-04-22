//! stack — low-level networking stack building blocks.
//!
//! This namespace currently exposes the generic Link contract used by
//! future stack implementations over PPP, Ethernet, TUN, TAP, or other
//! media.

pub const Link = @import("stack/Link.zig");
pub const Stack = @import("stack/Stack.zig");
