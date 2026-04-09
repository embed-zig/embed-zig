const embed = @import("embed");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runCases(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn runCases(comptime lib: type) !void {
    const TestCase = struct {
        fn makeExposesImplSymbols() !void {
            const testing = embed.testing.make(lib.testing);

            try testing.expect(true);
            const bytes = try testing.allocator.dupe(u8, "test");
            defer testing.allocator.free(bytes);
            try testing.expectEqual(@as(usize, 4), bytes.len);
        }
    };

    try TestCase.makeExposesImplSymbols();
}
