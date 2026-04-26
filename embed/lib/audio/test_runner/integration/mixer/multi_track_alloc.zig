const glib = @import("glib");
const MixerMod = @import("../../../Mixer.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const DefaultMixerType = MixerMod.make(grt);
    const CountingAllocator = test_utils.CountingAllocatorType(grt);

    const TestCase = struct {
        fn run(allocator: glib.std.mem.Allocator) !void {
            var counting = CountingAllocator.init(allocator);
            const counted = counting.allocator();

            const mixer = try DefaultMixerType.init(.{
                .allocator = counted,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const a = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer a.track.deinit();
            defer a.ctrl.deinit();
            const b = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer b.track.deinit();
            defer b.ctrl.deinit();

            const left = [_]i16{ 1, 1, 1, 1 };
            const right = [_]i16{ 2, 2, 2, 2 };
            const expected = [_]i16{ 3, 3, 3, 3 };
            const baseline = counting.snapshot();

            for (0..8) |_| {
                try a.track.write(.{ .rate = 16000, .channels = .mono }, &left);
                try b.track.write(.{ .rate = 16000, .channels = .mono }, &right);
                var out: [expected.len]i16 = undefined;
                const n = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
                try grt.std.testing.expectEqual(expected.len, n);
                try grt.std.testing.expectEqualSlices(i16, &expected, out[0..n]);
            }

            const after = counting.snapshot();
            try grt.std.testing.expectEqual(baseline.alloc_count, after.alloc_count);
            try grt.std.testing.expectEqual(baseline.resize_count, after.resize_count);
            try grt.std.testing.expectEqual(baseline.remap_count, after.remap_count);
        }
    };

    return glib.testing.TestRunner.fromFn(grt.std, 128 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try TestCase.run(allocator);
        }
    }.run);
}
