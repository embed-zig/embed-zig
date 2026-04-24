const testing_api = @import("testing");
const builtin = @import("builtin");

pub const Transport = @import("../Transport.zig");
pub const LineReader = @import("../LineReader.zig");
pub const Session = @import("../Session.zig");
pub const Dte = @import("../Dte.zig");
pub const Dce = @import("../Dce.zig");
pub const dte_loopback = @import("test_utils/dte_loopback.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            if (builtin.target.os.tag == .freestanding) {
                return true;
            }

            t.parallel();
            t.run("Transport", Transport.TestRunner(lib));
            t.run("LineReader", LineReader.TestRunner(lib));
            t.run("Session", Session.TestRunner(lib));
            t.run("Dte", Dte.TestRunner(lib));
            t.run("Dce", Dce.TestRunner(lib));
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
