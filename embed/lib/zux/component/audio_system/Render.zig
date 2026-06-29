const glib = @import("glib");

const State = @import("State.zig");

pub fn render(state: State, audio_system: anytype) !void {
    try audio_system.setSpkGain(state.gain_db);

    if (state.mic_gain_count != 0) {
        try audio_system.setMicGains(state.mic_gains[0..state.mic_gain_count]);
    }

    if (state.started) {
        try audio_system.start();
    } else {
        try audio_system.stop();
    }
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Call = enum {
        set_spk_gain,
        set_mic_gains,
        start,
        stop,
    };

    const FakeAudioSystem = struct {
        calls: [4]Call = undefined,
        call_count: usize = 0,
        gain_db: i8 = 0,
        mic_gain_count: usize = 0,
        mic_gains: [State.max_mic_gains]?i8 = [_]?i8{null} ** State.max_mic_gains,

        fn record(self: *@This(), call: Call) void {
            self.calls[self.call_count] = call;
            self.call_count += 1;
        }

        pub fn setSpkGain(self: *@This(), gain_db: i8) !void {
            self.record(.set_spk_gain);
            self.gain_db = gain_db;
        }

        pub fn setMicGains(self: *@This(), gains_db: []const ?i8) !void {
            self.record(.set_mic_gains);
            self.mic_gain_count = gains_db.len;
            for (gains_db, 0..) |gain_db, i| {
                self.mic_gains[i] = gain_db;
            }
        }

        pub fn start(self: *@This()) !void {
            self.record(.start);
        }

        pub fn stop(self: *@This()) !void {
            self.record(.stop);
        }
    };

    const TestCase = struct {
        fn render_applies_gains_before_stop() !void {
            var audio_system = FakeAudioSystem{};
            try render(.{
                .started = false,
                .gain_db = -12,
                .mic_gain_count = 2,
                .mic_gains = .{ -9, -6, null, null, null, null, null, null },
            }, &audio_system);

            try grt.std.testing.expectEqual(@as(usize, 3), audio_system.call_count);
            try grt.std.testing.expectEqual(Call.set_spk_gain, audio_system.calls[0]);
            try grt.std.testing.expectEqual(Call.set_mic_gains, audio_system.calls[1]);
            try grt.std.testing.expectEqual(Call.stop, audio_system.calls[2]);
            try grt.std.testing.expectEqual(@as(i8, -12), audio_system.gain_db);
            try grt.std.testing.expectEqual(@as(usize, 2), audio_system.mic_gain_count);
            try grt.std.testing.expectEqual(@as(?i8, -9), audio_system.mic_gains[0]);
            try grt.std.testing.expectEqual(@as(?i8, -6), audio_system.mic_gains[1]);
        }

        fn render_applies_gain_before_start() !void {
            var audio_system = FakeAudioSystem{};
            try render(.{
                .started = true,
                .gain_db = -3,
            }, &audio_system);

            try grt.std.testing.expectEqual(@as(usize, 2), audio_system.call_count);
            try grt.std.testing.expectEqual(Call.set_spk_gain, audio_system.calls[0]);
            try grt.std.testing.expectEqual(Call.start, audio_system.calls[1]);
            try grt.std.testing.expectEqual(@as(i8, -3), audio_system.gain_db);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.render_applies_gains_before_stop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.render_applies_gain_before_start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
