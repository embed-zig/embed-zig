const testing_api = @import("testing");

pub const Transport = @import("unit/Transport.zig");
pub const LineReader = @import("unit/LineReader.zig");
pub const Session = @import("unit/Session.zig");
pub const Dte = @import("unit/Dte.zig");
pub const Dce = @import("unit/Dce.zig");
pub const dte_loopback = @import("dte_loopback.zig");

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
            t.run("Transport", Transport.make(lib));
            t.run("LineReader", LineReader.make(lib));
            t.run("Session", Session.make(lib));
            t.run("Dte", Dte.make(lib));
            t.run("Dce", Dce.make(lib));
            t.run("dte_loopback", dte_loopback.make(lib, 64));
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
