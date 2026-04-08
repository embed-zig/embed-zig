const embed = @import("embed");
const testing_api = @import("testing");

const Transport = @import("../../Transport.zig");
const LineReaderMod = @import("../../LineReader.zig");
const Session = @import("../../Session.zig");
const Dte = @import("../../Dte.zig");
const Dce = @import("../../Dce.zig");
const dte_loopback = @import("../dte_loopback.zig");

fn runSmoke(comptime lib: type) !void {
    const E = embed.make(lib);
    _ = Transport;
    _ = LineReaderMod.LineReader(64);
    _ = Session.make(E, 64);
    _ = Dte.make(E, 64);
    _ = Dce.handleLine;
    try dte_loopback.runSurface(E, 64);
}

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runSmoke(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
