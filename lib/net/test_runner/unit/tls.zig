const testing_api = @import("testing");
const alert = @import("../../tls/alert.zig");
const client_handshake = @import("../../tls/client_handshake.zig");
const common = @import("../../tls/common.zig");
const conn = @import("../../tls/Conn.zig");
const extensions = @import("../../tls/extensions.zig");
const kdf = @import("../../tls/kdf.zig");
const record = @import("../../tls/record.zig");
const server_conn = @import("../../tls/ServerConn.zig");
const server_handshake = @import("../../tls/server_handshake.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("alert", alert.TestRunner(lib));
            t.run("common", common.TestRunner(lib));
            t.run("extensions", extensions.TestRunner(lib));
            t.run("kdf", kdf.TestRunner(lib));
            t.run("record", record.TestRunner(lib));
            t.run("client_handshake", client_handshake.TestRunner(lib));
            t.run("server_handshake", server_handshake.TestRunner(lib));
            t.run("Conn", conn.TestRunner(lib));
            t.run("ServerConn", server_conn.TestRunner(lib));
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
