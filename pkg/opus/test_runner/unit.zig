const testing_api = @import("testing");
const packet = @import("../src/Packet.zig");
const encoder = @import("../src/Encoder.zig");
const decoder = @import("../src/Decoder.zig");
const types = @import("../src/types.zig");
const opus_error = @import("../src/error.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("Packet", packet.TestRunner(lib));
            t.run("Encoder", encoder.TestRunner(lib));
            t.run("Decoder", decoder.TestRunner(lib));
            t.run("types", types.TestRunner(lib));
            t.run("error", opus_error.TestRunner(lib));
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
