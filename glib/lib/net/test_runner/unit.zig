//! Aggregates `lib/net` unit `TestRunner`s directly from source files. Topic
//! runners that still group multiple file-local tests live in the corresponding
//! namespace source (for example `http.zig` and `tls.zig`).

const testing_api = @import("testing");
const cmux_mod = @import("../Cmux.zig");
const http_mod = @import("../http.zig");
const netip_mod = @import("../netip.zig");
const ntp_mod = @import("../ntp.zig");
const resolver_mod = @import("../Resolver.zig");
const tcp_listener = @import("../TcpListener.zig");
const textproto_mod = @import("../textproto.zig");
const tls_mod = @import("../tls.zig");
const url_mod = @import("../url.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("netip", netip_mod.TestRunner(lib));
            t.run("url", url_mod.TestRunner(lib));
            t.run("http", http_mod.TestRunner(lib, net));
            t.run("textproto", textproto_mod.TestRunner(lib));
            t.run("cmux", cmux_mod.TestRunner(lib));
            t.run("ntp", ntp_mod.TestRunner(lib, net));
            t.run("resolver", resolver_mod.TestRunner(lib, net));
            t.run("tls", tls_mod.TestRunner(lib, net));
            t.run("TcpListener", tcp_listener.TestRunner(lib, net));
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
