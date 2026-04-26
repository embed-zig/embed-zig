const glib = @import("glib");
const MixerMod = @import("../../../Mixer.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const DefaultMixerType = MixerMod.make(grt);
    const Track = MixerMod.Track;

    const TestCase = struct {
        fn run(allocator: glib.std.mem.Allocator) !void {
            const Atomic = grt.std.atomic.Value;
            const Thread = grt.std.Thread;

            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = 2 });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2 });

            const State = struct {
                track: Track,
                started: Atomic(bool) = Atomic(bool).init(false),
                finished: Atomic(bool) = Atomic(bool).init(false),
                result: ?anyerror = null,
            };

            var state = State{ .track = handle.track };

            const writer = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    s.started.store(true, .release);
                    s.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 3, 4 }) catch |err| {
                        s.result = err;
                    };
                    s.finished.store(true, .release);
                }
            }.run, .{&state});

            try test_utils.waitUntilTrue(grt, &state.started, error.WriterDidNotStart);

            for (0..1000) |_| {
                if (state.finished.load(.acquire)) break;
                Thread.yield() catch {};
            }
            try grt.std.testing.expect(!state.finished.load(.acquire));

            mixer.closeWithError();

            writer.join();
            try grt.std.testing.expect(state.finished.load(.acquire));
            try grt.std.testing.expect(state.result != null);

            var post_close_err: ?anyerror = null;
            handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{5}) catch |err| {
                post_close_err = err;
            };
            try grt.std.testing.expect(post_close_err != null);

            var out: [4]i16 = undefined;
            try grt.std.testing.expectEqual(@as(?usize, null), mixer.read(&out));
        }
    };

    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try TestCase.run(allocator);
        }
    }.run);
}
