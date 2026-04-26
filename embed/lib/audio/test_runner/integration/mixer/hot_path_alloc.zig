const glib = @import("glib");
const MixerMod = @import("../../../Mixer.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
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

    // Slightly deeper control flow + allocations on worker than other mixer cases.
    return glib.testing.TestRunner.fromFn(lib, 128 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try TestCase.run(allocator);
        }
    }.run);
}
