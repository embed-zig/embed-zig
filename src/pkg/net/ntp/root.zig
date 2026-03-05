pub const ntp = @import("ntp.zig");

pub const Ipv4Address = ntp.Ipv4Address;
pub const NTP_PORT = ntp.NTP_PORT;
pub const NTP_UNIX_OFFSET = ntp.NTP_UNIX_OFFSET;
pub const NtpError = ntp.NtpError;
pub const Response = ntp.Response;
pub const Servers = ntp.Servers;
pub const ServerLists = ntp.ServerLists;
pub const Client = ntp.Client;
pub const generateNonce = ntp.generateNonce;
pub const formatTime = ntp.formatTime;

test {
    _ = ntp;
}
