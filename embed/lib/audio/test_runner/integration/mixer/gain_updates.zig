const glib = @import("glib");
const MixerMod = @import("../../../Mixer.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const DefaultMixerType = MixerMod.make(grt);

    const TestCase = struct {
        fn run(allocator: glib.std.mem.Allocator) !void {
            const Thread = grt.std.Thread;

            const total_samples = 256;
            const out_chunk = 4;

            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = total_samples });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            var input: [total_samples]i16 = undefined;
            @memset(&input, 100);
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &input);

            const State = struct {
                mixer: MixerMod,
                mutex: Thread.Mutex = .{},
                cond: Thread.Condition = .{},
                started: bool = false,
                active: bool = false,
                draining: bool = false,
                finished: bool = false,
                reads_in_phase: usize = 0,
                target_reads: usize = 0,
                saw_zero: bool = false,
                saw_nonzero: bool = false,
                bad_sample: bool = false,
                seen: usize = 0,
            };

            var state = State{
                .mixer = mixer,
            };

            const reader = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    var out: [out_chunk]i16 = undefined;
                    s.mutex.lock();
                    s.started = true;
                    s.cond.broadcast();
                    s.mutex.unlock();
                    while (true) {
                        s.mutex.lock();
                        while (!s.active and !s.finished) s.cond.wait(&s.mutex);
                        const draining = s.draining;
                        const finished = s.finished;
                        s.mutex.unlock();
                        if (finished) return;

                        if (s.mixer.read(&out)) |n| {
                            if (n == 0) {
                                Thread.yield() catch {};
                                continue;
                            }
                            s.mutex.lock();
                            for (out[0..n]) |sample| {
                                if (sample == 0) {
                                    s.saw_zero = true;
                                } else {
                                    s.saw_nonzero = true;
                                }
                                if (sample < 0 or sample > 100) s.bad_sample = true;
                            }
                            s.seen += n;
                            if (!draining) {
                                s.reads_in_phase += 1;
                                if (s.reads_in_phase >= s.target_reads) {
                                    s.active = false;
                                    s.cond.broadcast();
                                }
                            }
                            s.mutex.unlock();
                            continue;
                        }
                        s.mutex.lock();
                        s.finished = true;
                        s.active = false;
                        s.cond.broadcast();
                        s.mutex.unlock();
                        break;
                    }
                }
            }.run, .{&state});

            state.mutex.lock();
            while (!state.started) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(1.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 4;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(0.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 12;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(1.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 12;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            mixer.closeWrite();
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 0;
            state.draining = true;
            state.active = true;
            state.cond.broadcast();
            while (!state.finished) state.cond.wait(&state.mutex);
            state.mutex.unlock();
            reader.join();

            try grt.std.testing.expectEqual(@as(usize, total_samples), state.seen);
            try grt.std.testing.expect(!state.bad_sample);
            try grt.std.testing.expect(state.saw_zero);
            try grt.std.testing.expect(state.saw_nonzero);
        }
    };

    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try TestCase.run(allocator);
        }
    }.run);
}
