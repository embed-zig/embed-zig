//! http — HTTP module namespace.
//!
//! This file exposes the current HTTP request/response types, the high-level
//! client facade, and the lower-level round tripper / transport contracts.

pub const Header = @import("http/Header.zig");
pub const ReadCloser = @import("http/ReadCloser.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const status = @import("http/status.zig");
pub const RoundTripper = @import("http/RoundTripper.zig");
const client_mod = @import("http/Client.zig");
const transport_mod = @import("http/Transport.zig");

pub fn Client(comptime lib: type) type {
    return client_mod.Client(lib);
}

pub fn Transport(comptime lib: type) type {
    return transport_mod.Transport(lib);
}

pub fn make(comptime lib: type) type {
    return struct {
        pub const Header = @import("http/Header.zig");
        pub const ReadCloser = @import("http/ReadCloser.zig");
        pub const Request = @import("http/Request.zig");
        pub const Response = @import("http/Response.zig");
        pub const status = @import("http/status.zig");
        pub const RoundTripper = @import("http/RoundTripper.zig");
        pub const Client = client_mod.Client(lib);
        pub const Transport = transport_mod.Transport(lib);
    };
}
