const glib = @import("glib");

const consts = @import("../consts.zig");

const Signal = enum {
    sync,
    quit,
};

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime AudioSystem: type) type {
    const AtomicBool = grt.std.atomic.Value(bool);
    const SignalChannel = grt.sync.Channel(Signal);
    const log = grt.std.log.scoped(.chant_recorder);

    return struct {
        const Runtime = @This();
        const TrackHandle = AudioSystem.TrackHandle;

        allocator: glib.std.mem.Allocator,
        zux_app: *ZuxAppType,
        signal: SignalChannel,
        task_options: glib.task.Options,
        running: AtomicBool = AtomicBool.init(false),
        task: ?grt.task.Handle = null,
        core: Core = .{},
        last_notified_recording: ?bool = null,

        pub fn init(
            allocator: glib.std.mem.Allocator,
            zux_app: *ZuxAppType,
            task_options: glib.task.Options,
        ) !Runtime {
            return .{
                .allocator = allocator,
                .zux_app = zux_app,
                .signal = try SignalChannel.make(allocator, 1),
                .task_options = task_options,
            };
        }

        pub fn start(self: *Runtime) !void {
            if (self.task != null) return;
            self.running.store(true, .release);
            errdefer self.running.store(false, .release);
            self.task = try grt.task.go(
                "zux/chant/recorder",
                self.task_options,
                glib.task.Routine.init(self, loop),
            );
            self.notifySync();
        }

        pub fn notifySync(self: *Runtime) void {
            const player = self.zux_app.store.stores.player.get();
            if (self.last_notified_recording == null or self.last_notified_recording.? != player.recording) {
                log.info("notify sync recording={}", .{player.recording});
                self.last_notified_recording = player.recording;
            }
            self.notify(.sync);
        }

        pub fn deinit(self: *Runtime) void {
            self.stop();
            self.signal.deinit();
            self.* = undefined;
        }

        fn stop(self: *Runtime) void {
            self.running.store(false, .release);
            self.notify(.quit);
            self.signal.close();
            if (self.task) |task| {
                task.join();
                self.task = null;
            }
            const system = self.zux_app.audioSystem(.audio);
            self.core.deinit(system);
        }

        fn notify(self: *Runtime, signal: Signal) void {
            _ = self.signal.sendTimeout(signal, consts.notify_timeout) catch return;
        }

        fn loop(self: *Runtime) void {
            log.info("recorder thread started", .{});
            while (self.running.load(.acquire)) {
                const player = self.zux_app.store.stores.player.get();
                const system = self.zux_app.audioSystem(.audio);

                self.core.sync(system, player.recording) catch |err| {
                    log.err("recording sync failed: {s}", .{@errorName(err)});
                };
                if (!player.recording) {
                    if (!self.waitForSignal(null)) break;
                    continue;
                }

                const did_read = self.core.readFrame(system) catch {
                    grt.time.sleep(consts.recorder.retry_interval);
                    continue;
                };
                if (!did_read) {
                    grt.time.sleep(consts.recorder.retry_interval);
                }
            }
            log.info("recorder thread stopped", .{});
        }

        fn waitForSignal(self: *Runtime, timeout: ?glib.time.duration.Duration) bool {
            const result = if (timeout) |duration|
                self.signal.recvTimeout(duration) catch |err| switch (err) {
                    error.Timeout => return true,
                    else => return false,
                }
            else
                self.signal.recv() catch |err| {
                    log.info("wait signal stopped: {s}", .{@errorName(err)});
                    return false;
                };

            if (!result.ok) return true;
            log.info("received signal {s}", .{@tagName(result.value)});
            return result.value != .quit;
        }

        const Core = struct {
            recording: bool = false,
            loopback_track: ?TrackHandle = null,
            read_attempts: usize = 0,
            reads: usize = 0,
            writes: usize = 0,
            would_block_count: usize = 0,
            error_count: usize = 0,
            input_peak: u16 = 0,
            output_peak: u16 = 0,
            current_input_peak: u16 = 0,
            current_output_peak: u16 = 0,
            frame: [consts.recorder.frame_sample_count]i16 = [_]i16{0} ** consts.recorder.frame_sample_count,

            fn sync(self: *Core, system: *AudioSystem, recording: bool) !void {
                if (recording and !self.recording) {
                    system.discardReadBuffer();
                    self.resetStats();
                    self.loopback_track = try system.createTrack(.{
                        .label = "mic-loopback",
                        .gain = 1.0,
                        .buffer_capacity = consts.recorder.track_buffer_capacity,
                        .reference = false,
                    });
                    log.info("recording started", .{});
                } else if (!recording and self.recording) {
                    self.report("recording stopped");
                    self.closeLoopbackTrack();
                }
                self.recording = recording;
            }

            fn readFrame(self: *Core, system: *AudioSystem) !bool {
                self.read_attempts += 1;
                const read_started = grt.time.instant.now();
                const n = system.read(self.frame[0..]) catch |err| {
                    self.reportSlowRead("recording read error", read_started);
                    switch (err) {
                        error.WouldBlock => self.would_block_count += 1,
                        else => self.error_count += 1,
                    }
                    if (err != error.WouldBlock) {
                        log.err("recording read failed: {s}", .{@errorName(err)});
                    }
                    self.reportEveryStride("recording pending");
                    return false;
                };
                self.reportSlowRead("recording read ok", read_started);
                if (n == 0) {
                    self.reportEveryStride("recording empty");
                    return false;
                }

                self.reads += 1;
                self.current_input_peak = peakAbs(self.frame[0..n]);
                self.input_peak = @max(self.input_peak, self.current_input_peak);
                applyGain(self.frame[0..n]);
                self.current_output_peak = peakAbs(self.frame[0..n]);
                self.output_peak = @max(self.output_peak, self.current_output_peak);
                if (self.loopback_track) |*handle| {
                    const write_started = grt.time.instant.now();
                    try handle.track.write(.{
                        .rate = system.spkSampleRate() catch consts.player.default_sample_rate_hz,
                        .channels = .mono,
                    }, self.frame[0..n]);
                    self.reportSlowWrite(write_started);
                    self.writes += 1;
                }
                self.reportEveryStride("recording active");
                return true;
            }

            fn deinit(self: *Core, system: *AudioSystem) void {
                _ = system;
                self.closeLoopbackTrack();
                self.recording = false;
            }

            fn closeLoopbackTrack(self: *Core) void {
                if (self.loopback_track) |*handle| {
                    handle.ctrl.closeWithError();
                    handle.ctrl.deinit();
                    handle.track.deinit();
                    self.loopback_track = null;
                }
            }

            fn resetStats(self: *Core) void {
                self.read_attempts = 0;
                self.reads = 0;
                self.writes = 0;
                self.would_block_count = 0;
                self.error_count = 0;
                self.input_peak = 0;
                self.output_peak = 0;
                self.current_input_peak = 0;
                self.current_output_peak = 0;
            }

            fn reportEveryStride(self: *Core, comptime message: []const u8) void {
                if (self.read_attempts % consts.recorder.report_stride != 0) return;
                self.report(message);
            }

            fn report(self: *Core, comptime message: []const u8) void {
                log.info(
                    "{s}: attempts={d} reads={d} writes={d} would_block={d} errors={d} input_peak={d} output_peak={d} current_input_peak={d} current_output_peak={d}",
                    .{
                        message,
                        self.read_attempts,
                        self.reads,
                        self.writes,
                        self.would_block_count,
                        self.error_count,
                        self.input_peak,
                        self.output_peak,
                        self.current_input_peak,
                        self.current_output_peak,
                    },
                );
            }

            fn reportSlowRead(self: *Core, comptime message: []const u8, started: grt.time.instant.Time) void {
                _ = self;
                const elapsed = grt.time.instant.sub(grt.time.instant.now(), started);
                if (elapsed < consts.recorder.slow_io_threshold) return;
                log.info("{s}: elapsed_ms={d}", .{ message, @divTrunc(elapsed, glib.time.duration.MilliSecond) });
            }

            fn reportSlowWrite(self: *Core, started: grt.time.instant.Time) void {
                _ = self;
                const elapsed = grt.time.instant.sub(grt.time.instant.now(), started);
                if (elapsed < consts.recorder.slow_io_threshold) return;
                log.info("recording loopback write: elapsed_ms={d}", .{@divTrunc(elapsed, glib.time.duration.MilliSecond)});
            }
        };
    };
}

fn applyGain(samples: []i16) void {
    for (samples) |*sample| {
        sample.* = clampSample(@as(f32, @floatFromInt(sample.*)) * consts.recorder.loopback_gain);
    }
}

fn peakAbs(samples: []const i16) u16 {
    var peak: u16 = 0;
    for (samples) |sample| {
        const value: i32 = sample;
        const abs: u16 = @intCast(if (value < 0) -value else value);
        peak = @max(peak, abs);
    }
    return peak;
}

fn clampSample(value: f32) i16 {
    if (value > 32767.0) return 32767;
    if (value < -32768.0) return -32768;
    return @intFromFloat(value);
}
