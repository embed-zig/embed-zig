const testing_api = @import("testing");

const tcp = @import("integration/tcp.zig");
const udp = @import("integration/udp.zig");
const tls = @import("integration/tls.zig");
const http_client = @import("integration/http_client.zig");
const http_server = @import("integration/http_server.zig");
const http_transport = @import("integration/http_transport.zig");
const https_transport = @import("integration/https_transport.zig");
const cmux = @import("integration/cmux.zig");
const resolver_local = @import("integration/resolver_local.zig");
const ntp_public = @import("integration/public/ntp.zig");
const runtime_runner = @import("integration/runtime.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("tcp", tcp.make(std, net));
            t.run("udp", udp.make(std, net));
            t.run("tls", tls.make(std, net));
            t.run("resolver_local", resolver_local.make(std, net));
            t.run("cmux_http_tcp", cmux.make(std, net));
            t.run("http_client", http_client.make(std, net));
            t.run("http_server", http_server.make(std, net));
            t.run("http_transport", http_transport.make2(std, net));
            t.run("https_transport", https_transport.make(std, net));
            t.run("ntp_public", ntp_public.make(std, net));
            t.run("runtime", runtime_runner.make(std, net));
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
