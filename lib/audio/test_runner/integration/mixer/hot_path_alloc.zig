const testing_api = @import("testing");
const MixerMod = @import("../../../Mixer.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const DefaultMixerType = MixerMod.make(lib);
    const CountingAllocator = test_utils.CountingAllocatorType(lib);

    const TestCase = struct {
        fn run(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var counting = CountingAllocator.init(allocator);
            const counted = counting.allocator();

            const mixer = try DefaultMixerType.init(.{
                .allocator = counted,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            const samples = [_]i16{ 1, 2, 3, 4 };
            const baseline = counting.snapshot();

            for (0..8) |_| {
                try handle.track.write(.{ .rate = 16000, .channels = .mono }, &samples);
                var out: [samples.len]i16 = undefined;
                const n = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
                try testing.expectEqual(samples.len, n);
                try testing.expectEqualSlices(i16, &samples, out[0..n]);
            }

            const after = counting.snapshot();
            try testing.expectEqual(baseline.alloc_count, after.alloc_count);
            try testing.expectEqual(baseline.resize_count, after.resize_count);
            try testing.expectEqual(baseline.remap_count, after.remap_count);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            TestCase.run(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
