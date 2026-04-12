const testing_api = @import("testing");

const apn = @import("modem/apn.zig");
const attach = @import("modem/attach.zig");
const call = @import("modem/call.zig");
const gnss = @import("modem/gnss.zig");
const mixed = @import("modem/mixed.zig");
const signal = @import("modem/signal.zig");
const sms = @import("modem/sms.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("attach", attach.make(lib, Channel));
            t.run("signal", signal.make(lib, Channel));
            t.run("apn", apn.make(lib, Channel));
            t.run("call", call.make(lib, Channel));
            t.run("sms", sms.make(lib, Channel));
            t.run("gnss", gnss.make(lib, Channel));
            t.run("mixed", mixed.make(lib, Channel));
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
