//! textproto — shared text-protocol helpers for `lib/net`.

pub const Reader = @import("textproto/Reader.zig").Reader;
pub const Writer = @import("textproto/Writer.zig").Writer;

pub fn make(comptime std: type) type {
    _ = std;

    return struct {
        pub const Reader = @import("textproto/Reader.zig").Reader;
        pub const Writer = @import("textproto/Writer.zig").Writer;
    };
}

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Reader", @import("textproto/Reader.zig").TestRunner(std));
            t.run("Writer", @import("textproto/Writer.zig").TestRunner(std));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
