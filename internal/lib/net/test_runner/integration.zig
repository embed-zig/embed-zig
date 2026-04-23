const stdz = @import("stdz");
const testing_api = @import("testing");

const fd_stream = @import("integration/fd_stream.zig");
const fd_packet = @import("integration/fd_packet.zig");
const tcp = @import("integration/tcp.zig");
const udp = @import("integration/udp.zig");
const tls = @import("integration/tls.zig");
const http_client = @import("integration/http_client.zig");
const http_server = @import("integration/http_server.zig");
const http_transport = @import("integration/http_transport.zig");
const https_transport = @import("integration/https_transport.zig");
const cmux = @import("integration/cmux.zig");
const resolver_local = @import("integration/resolver_local.zig");
const runtime_runner = @import("integration/runtime.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("fd_stream", fd_stream.make(lib));
            t.run("fd_packet", fd_packet.make(lib));
            t.run("tcp", tcp.make(lib));
            t.run("udp", udp.make(lib));
            t.run("tls", tls.make(lib));
            t.run("resolver_local", resolver_local.make(lib));
            t.run("cmux_http_tcp", cmux.make(lib));
            t.run("http_client", http_client.make(lib));
            t.run("http_server", http_server.make(lib));
            t.run("http_transport", http_transport.make(lib));
            t.run("https_transport", https_transport.make(lib));
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

/// Integration slice for `net.make2(lib, impl).Runtime` only.
///
/// `Net2` is the struct type returned by `net.make2` (namespace with `Runtime`).
pub fn make2(comptime Net2: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("runtime", runtime_runner.make(Net2));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
