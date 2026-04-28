//! http — HTTP module namespace.
//!
//! This file exposes the current HTTP request/response types, the high-level
//! client facade, and the lower-level round tripper / transport contracts.

pub const Header = @import("http/Header.zig");
const handler_mod = @import("http/Handler.zig");
pub const ReadCloser = @import("http/ReadCloser.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const status = @import("http/status.zig");
pub const RoundTripper = @import("http/RoundTripper.zig");
const client_mod = @import("http/Client.zig");
const response_writer_mod = @import("http/ResponseWriter.zig");
const serve_mux_mod = @import("http/ServeMux.zig");
const static_serve_mux_mod = @import("http/StaticServeMux.zig");
const server_mod = @import("http/Server.zig");
const transport_mod = @import("http/Transport.zig");

pub fn make(comptime std: type, comptime net: type) type {
    return struct {
        pub const Header = @import("http/Header.zig");
        pub const ReadCloser = @import("http/ReadCloser.zig");
        pub const Request = @import("http/Request.zig");
        pub const Response = @import("http/Response.zig");
        pub const status = @import("http/status.zig");
        pub const RoundTripper = @import("http/RoundTripper.zig");
        pub const Handler = handler_mod.Handler(std);
        pub const HandlerFunc = handler_mod.HandlerFunc(std);
        pub const ResponseWriter = response_writer_mod.ResponseWriter(std);
        pub const ServeMux = serve_mux_mod.ServeMux(std);
        pub fn StaticServeMux(comptime spec: anytype) type {
            return static_serve_mux_mod.StaticServeMux(std, spec);
        }
        pub const Server = server_mod.Server(std, net);
        pub const Client = client_mod.Client(std);
        pub const Transport = transport_mod.Transport(std, net);
    };
}

pub fn TestRunner(comptime std: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("Header", Header.TestRunner(std));
            t.run("ReadCloser", ReadCloser.TestRunner(std));
            t.run("Request", Request.TestRunner(std, net.time));
            t.run("Response", Response.TestRunner(std));
            t.run("Handler", handler_mod.TestRunner(std));
            t.run("ServeMux", serve_mux_mod.TestRunner(std));
            t.run("StaticServeMux", static_serve_mux_mod.TestRunner(std));
            t.run("ResponseWriter", response_writer_mod.TestRunner(std));
            t.run("Server", server_mod.TestRunner(std, net));
            t.run("Client", client_mod.TestRunner(std));
            t.run("Transport", transport_mod.TestRunner(std, net));
            t.run("status", status.TestRunner(std));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
