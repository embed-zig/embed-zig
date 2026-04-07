const embed = @import("embed");
const testing_api = @import("testing");

const binding = @import("../../src/binding.zig");
const types_mod = @import("../../src/types.zig");
const Page = @import("../../src/Page.zig");
const Sync = @import("../../src/Sync.zig");
const Stream = @import("../../src/Stream.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("binding", binding.TestRunner(lib));
            t.run("types", types_mod.TestRunner(lib));
            t.run("Page", Page.TestRunner(lib));
            t.run("Sync", Sync.TestRunner(lib));
            t.run("Stream", Stream.TestRunner(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
