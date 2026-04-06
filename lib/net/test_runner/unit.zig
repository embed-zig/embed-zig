const testing_api = @import("testing");

pub const netip = @import("unit/netip.zig");
pub const url = @import("unit/url.zig");
pub const http = @import("unit/http.zig");
pub const ntp = @import("unit/ntp.zig");
pub const stack = @import("unit/stack.zig");
pub const resolver = @import("unit/resolver.zig");
pub const tls = @import("unit/tls.zig");
pub const fd = @import("unit/fd.zig");
pub const core = @import("unit/core.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("netip", netip.make(lib));
            t.run("url", url.make(lib));
            t.run("http", http.make(lib));
            t.run("ntp", ntp.make(lib));
            t.run("stack", stack.make(lib));
            t.run("resolver", resolver.make(lib));
            t.run("tls", tls.make(lib));
            t.run("fd", fd.make(lib));
            t.run("core", core.make(lib));
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
