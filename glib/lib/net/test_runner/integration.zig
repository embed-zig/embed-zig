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
const std_facade = @import("integration/std_facade.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const test_std = std_facade.make(std, net);

    const Runner = struct {
        pub fn init(self: *@This(), allocator: test_std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: test_std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("tcp", tcp.make(test_std, net));
            t.run("udp", udp.make(test_std, net));
            t.run("tls", tls.make(test_std, net));
            t.run("resolver_local", resolver_local.make(test_std, net));
            t.run("cmux_http_tcp", cmux.make(test_std, net));
            t.run("http_client", http_client.make(test_std, net));
            t.run("http_server", http_server.make(test_std, net));
            t.run("http_transport", http_transport.make2(test_std, net));
            t.run("https_transport", https_transport.make(test_std, net));
            t.run("ntp_public", ntp_public.make(test_std, net));
            t.run("runtime", runtime_runner.make(test_std, net));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: test_std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
