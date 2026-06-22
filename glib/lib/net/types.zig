const netip = @import("netip.zig");

pub const InterfaceId = usize;

pub const AddressFamily = enum {
    ipv4,
    ipv6,
};

pub const AddressInfo = struct {
    family: AddressFamily,
    address: netip.Addr,
    prefix_len: u8 = 0,
};

pub const Error = error{
    Unsupported,
    InvalidInterface,
    InvalidRoute,
    BufferTooSmall,
    Unexpected,
};
