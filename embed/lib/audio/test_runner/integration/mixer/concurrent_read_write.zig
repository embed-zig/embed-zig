const glib = @import("glib");
const MixerMod = @import("../../../Mixer.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const DefaultMixerType = MixerMod.make(grt);
    const Track = MixerMod.Track;

    const TestCase = struct {
        fn run(allocator: glib.std.mem.Allocator) !void {
            const Atomic = grt.std.atomic.Value;
            const Thread = grt.std.Thread;

            const total_samples = 32;
            const chunk_len = 8;

            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = total_samples });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            const State = struct {
                track: Track,
                samples: [total_samples]i16,
                done: Atomic(bool) = Atomic(bool).init(false),
                result: ?anyerror = null,
            };

            var state = State{
                .track = handle.track,
                .samples = undefined,
            };
            for (&state.samples, 0..) |*sample, idx| {
                sample.* = @intCast(idx + 1);
            }

            const writer = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    var i: usize = 0;
                    while (i < s.samples.len) : (i += chunk_len) {
                        const upper = @min(i + chunk_len, s.samples.len);
                        s.track.write(.{ .rate = 8000, .channels = .mono }, s.samples[i..upper]) catch |err| {
                            s.result = err;
                            break;
                        };
                        Thread.yield() catch {};
                    }
                    s.done.store(true, .release);
                }
            }.run, .{&state});

            var collected: [total_samples]i16 = undefined;
            var collected_len: usize = 0;
            var close_requested = false;
            var out: [chunk_len]i16 = undefined;

            while (true) {
                if (state.done.load(.acquire) and !close_requested) {
                    mixer.closeWrite();
                    close_requested = true;
                }

                if (mixer.read(&out)) |n| {
                    if (n == 0) {
                        Thread.yield() catch {};
                        continue;
                    }
                    @memcpy(collected[collected_len .. collected_len + n], out[0..n]);
                    collected_len += n;
                    continue;
                }
                break;
            }

            writer.join();
            if (state.result) |err| return err;

            try grt.std.testing.expectEqual(@as(usize, total_samples), collected_len);
            try grt.std.testing.expectEqualSlices(i16, state.samples[0..], collected[0..collected_len]);
        }
    };

    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try TestCase.run(allocator);
        }
    }.run);
}
