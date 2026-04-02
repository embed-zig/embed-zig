const net = @import("net");

pub const max_ssid_len: usize = 32;
pub const MacAddr = [6]u8;
pub const Addr = net.netip.Addr;

pub const Security = enum {
    unknown,
    open,
    wep,
    wpa,
    wpa2,
    wpa3,
};
