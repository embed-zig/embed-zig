//! http — HTTP module namespace.
//!
//! This file currently exposes the round tripper contract used by the future
//! HTTP client/server implementation.

pub const Header = @import("http/Header.zig");
pub const ReadCloser = @import("http/ReadCloser.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const status = @import("http/status.zig");
pub const RoundTripper = @import("http/RoundTripper.zig");
const transport_mod = @import("http/Transport.zig");

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
        pub const Transport = transport_mod.Transport(lib);
    };
}
