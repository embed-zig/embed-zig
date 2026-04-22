//! ntp - UDP NTP client module surface.

const client_mod = @import("ntp/Client.zig");
const types_mod = @import("ntp/types.zig");
const wire_mod = @import("ntp/wire.zig");

const root = @This();

pub const types = types_mod;
pub const wire = wire_mod;

pub const NTP_PORT = types_mod.NTP_PORT;
pub const NTP_UNIX_OFFSET = types_mod.NTP_UNIX_OFFSET;
pub const QueryError = types_mod.QueryError;
pub const NtpTimestamp = types_mod.NtpTimestamp;
pub const Response = types_mod.Response;

pub const buildRequest = wire_mod.buildRequest;
pub const parseResponse = wire_mod.parseResponse;
pub const readTimestamp = wire_mod.readTimestamp;
pub const writeTimestamp = wire_mod.writeTimestamp;
pub const ntpToUnixMs = wire_mod.ntpToUnixMs;
pub const unixMsToNtp = wire_mod.unixMsToNtp;

pub fn generateNonce(comptime lib: type) i64 {
    return wire_mod.generateNonce(lib);
}

pub fn Client(comptime lib: type) type {
    return client_mod.Client(lib, root);
}

pub fn make(comptime lib: type) type {
    const C = Client(lib);
    return struct {
        pub const types = types_mod;
        pub const wire = wire_mod;
        pub const QueryError = root.QueryError;
        pub const NtpTimestamp = root.NtpTimestamp;
        pub const Response = root.Response;
        pub const NTP_PORT = root.NTP_PORT;
        pub const NTP_UNIX_OFFSET = root.NTP_UNIX_OFFSET;
        pub const Client = C;
        pub const Server = C.Server;
        pub const Servers = C.Servers;
        pub const buildRequest = root.buildRequest;
        pub const parseResponse = root.parseResponse;
        pub const readTimestamp = root.readTimestamp;
        pub const writeTimestamp = root.writeTimestamp;
        pub const ntpToUnixMs = root.ntpToUnixMs;
        pub const unixMsToNtp = root.unixMsToNtp;

        pub fn generateNonce() i64 {
            return root.generateNonce(lib);
        }
    };
}
