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

pub fn Client(comptime lib: type, comptime net: type) type {
    _ = net;
    return client_mod.Client(lib);
}

pub fn Handler(comptime lib: type, comptime net: type) type {
    _ = net;
    return handler_mod.Handler(lib);
}

pub fn HandlerFunc(comptime lib: type, comptime net: type) type {
    _ = net;
    return handler_mod.HandlerFunc(lib);
}

pub fn ResponseWriter(comptime lib: type, comptime net: type) type {
    _ = net;
    return response_writer_mod.ResponseWriter(lib);
}

pub fn ServeMux(comptime lib: type, comptime net: type) type {
    _ = net;
    return serve_mux_mod.ServeMux(lib);
}

pub fn StaticServeMux(comptime lib: type, comptime net: type, comptime spec: anytype) type {
    _ = net;
    return static_serve_mux_mod.StaticServeMux(lib, spec);
}

pub fn Server(comptime lib: type, comptime net: type) type {
    _ = net;
    return server_mod.Server(lib);
}

pub fn Transport(comptime lib: type, comptime net: type) type {
    return transport_mod.Transport(lib, net);
}

pub fn make(comptime lib: type, comptime net: type) type {
    return struct {
        pub const Header = @import("http/Header.zig");
        pub const ReadCloser = @import("http/ReadCloser.zig");
        pub const Request = @import("http/Request.zig");
        pub const Response = @import("http/Response.zig");
        pub const status = @import("http/status.zig");
        pub const RoundTripper = @import("http/RoundTripper.zig");
        pub const Handler = handler_mod.Handler(lib);
        pub const HandlerFunc = handler_mod.HandlerFunc(lib);
        pub const ResponseWriter = response_writer_mod.ResponseWriter(lib);
        pub const ServeMux = serve_mux_mod.ServeMux(lib);
        pub fn StaticServeMux(comptime spec: anytype) type {
            return static_serve_mux_mod.StaticServeMux(lib, spec);
        }
        pub const Server = server_mod.Server(lib);
        pub const Client = client_mod.Client(lib);
        pub const Transport = transport_mod.Transport(lib, net);
    };
}

pub fn TestRunner(comptime lib: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("Header", Header.TestRunner(lib));
            t.run("ReadCloser", ReadCloser.TestRunner(lib));
            t.run("Request", Request.TestRunner(lib));
            t.run("Response", Response.TestRunner(lib));
            t.run("Handler", handler_mod.TestRunner(lib));
            t.run("ServeMux", serve_mux_mod.TestRunner(lib));
            t.run("StaticServeMux", static_serve_mux_mod.TestRunner(lib));
            t.run("ResponseWriter", response_writer_mod.TestRunner(lib));
            t.run("Server", server_mod.TestRunner(lib));
            t.run("Client", client_mod.TestRunner(lib));
            t.run("Transport", transport_mod.TestRunner(lib, net));
            t.run("status", status.TestRunner(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
