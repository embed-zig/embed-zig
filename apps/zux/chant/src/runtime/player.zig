const glib = @import("glib");

const consts = @import("../consts.zig");
const playback_reducer = @import("../reducers/playback.zig");
const SongsMod = @import("player/Songs.zig");
const TracksMod = @import("player/Tracks.zig");

const Signal = enum {
    sync,
    quit,
};

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime AudioSystem: type) type {
    const AtomicBool = grt.std.atomic.Value(bool);
    const SignalChannel = grt.sync.Channel(Signal);
    const AppImpl = ZuxAppType.ImplType;
    const TrackType = TracksMod.Track(ZuxAppType);
    const Songs = SongsMod.make(ZuxAppType);
    const Tracks = TracksMod.make(ZuxAppType);
    const log = grt.std.log.scoped(.chant_player);

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
                "zux/chant/player",
                self.task_options,
                glib.task.Routine.init(self, loop),
            );
            self.notifySync();
        }

        pub fn notifySync(self: *Runtime) void {
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
            while (self.running.load(.acquire)) {
                const player = self.zux_app.store.stores.player.get();
                const audio_system = self.zux_app.store.stores.audio.get();
                const system = self.zux_app.audioSystem(.audio);

                self.core.sync(system, player.selected, player.playing, audio_system.gain_db) catch |err| {
                    log.err("sync failed: {s}", .{@errorName(err)});
                    grt.time.sleep(10 * grt.time.duration.MilliSecond);
                    continue;
                };
                if (!player.playing) {
                    if (!self.waitForSignal(null)) break;
                    continue;
                }

                const progress_pct = self.core.writeFrame(system, player.selected, player.loop) catch |err| {
                    log.err("write frame failed: {s}", .{@errorName(err)});
                    grt.time.sleep(1 * grt.time.duration.MilliSecond);
                    continue;
                };
                self.emitPlaybackProgress(progress_pct) catch {};
            }
        }

        fn waitForSignal(self: *Runtime, timeout: ?glib.time.duration.Duration) bool {
            const result = if (timeout) |duration|
                self.signal.recvTimeout(duration) catch |err| switch (err) {
                    error.Timeout => return true,
                    else => return false,
                }
            else
                self.signal.recv() catch return false;

            if (!result.ok) return true;
            return result.value != .quit;
        }

        fn emitPlaybackProgress(self: *Runtime, progress_pct: u8) !void {
            const payload = try playback_reducer.PlaybackProgress.init(self.allocator, progress_pct);
            _ = try self.zux_app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{
                    .custom = self.zux_app.initCustomEvent(
                        playback_reducer.PlaybackProgress,
                        AppImpl.sourceId(.audio),
                        payload,
                    ),
                },
            });
        }

        const Core = struct {
            current_track: ?u8 = null,
            active_track: ?TrackHandle = null,
            playing: bool = false,
            gain_db: i8 = 0,
            gain_initialized: bool = false,
            progress_ms: u32 = 0,
            system_started: bool = false,
            write_seq: usize = 0,
            write_probe_remaining: usize = 0,
            frame: [consts.player.frame_sample_count]i16 = [_]i16{0} ** consts.player.frame_sample_count,

            fn sync(self: *Core, system: *AudioSystem, track: TrackType, playing: bool, gain_db: i8) !void {
                try self.ensureStarted(system);
                if (!self.gain_initialized or self.gain_db != gain_db) {
                    log.info("set speaker gain db={}", .{gain_db});
                    try system.setSpkGain(gain_db);
                    self.gain_initialized = true;
                }
                if (self.playing != playing) {
                    log.info("playing {} -> {}", .{ self.playing, playing });
                }
                try self.ensureTrack(system, track);
                self.playing = playing;
                self.gain_db = gain_db;
            }

            fn writeFrame(self: *Core, system: *AudioSystem, track: TrackType, loop_track: bool) !u8 {
                try self.ensureStarted(system);
                try self.ensureTrack(system, track);
                const sample_rate = system.spkSampleRate() catch consts.player.default_sample_rate_hz;
                Songs.fillChunk(track, self.frame[0..], sample_rate, self.progress_ms, loop_track);
                if (self.active_track) |*handle| {
                    self.write_seq += 1;
                    const seq = self.write_seq;
                    const probe = self.write_probe_remaining > 0 or seq <= 5 or seq % 100 == 0;
                    const started = grt.time.instant.now();
                    if (probe) {
                        log.info(
                            "track write begin seq={} track={s} progress_ms={} samples={} rate={}",
                            .{ seq, Tracks.name(track), self.progress_ms, self.frame.len, sample_rate },
                        );
                    }
                    try handle.track.write(.{
                        .rate = sample_rate,
                        .channels = .mono,
                    }, self.frame[0..]);
                    const elapsed = grt.time.instant.sub(grt.time.instant.now(), started);
                    if (probe or elapsed >= 50 * grt.time.duration.MilliSecond) {
                        log.info(
                            "track write end seq={} track={s} elapsed_ms={}",
                            .{ seq, Tracks.name(track), @divTrunc(elapsed, grt.time.duration.MilliSecond) },
                        );
                    }
                    if (self.write_probe_remaining > 0) self.write_probe_remaining -= 1;
                }
                return self.advanceProgress(track, loop_track, self.frame.len, sample_rate);
            }

            fn deinit(self: *Core, system: *AudioSystem) void {
                self.closeActiveTrack();
                if (self.system_started) {
                    system.stop() catch {};
                    self.system_started = false;
                }
            }

            fn ensureStarted(self: *Core, system: *AudioSystem) !void {
                if (self.system_started) return;
                try system.start();
                self.system_started = true;
            }

            fn ensureTrack(self: *Core, system: *AudioSystem, track: TrackType) !void {
                const track_id = @intFromEnum(track);
                if (self.current_track != null and self.current_track.? == track_id and self.active_track != null) {
                    return;
                }

                self.closeActiveTrack();
                log.info("create track {s}", .{Tracks.name(track)});
                self.active_track = try system.createTrack(.{
                    .label = Tracks.name(track),
                    .buffer_capacity = consts.player.track_buffer_capacity,
                });
                log.info("created track {s}", .{Tracks.name(track)});
                self.current_track = track_id;
                self.progress_ms = 0;
                self.write_probe_remaining = 4;
            }

            fn closeActiveTrack(self: *Core) void {
                if (self.active_track) |*handle| {
                    log.info("close active track current={?}", .{self.current_track});
                    handle.ctrl.closeWithError();
                    handle.ctrl.deinit();
                    handle.track.deinit();
                    self.active_track = null;
                    log.info("closed active track", .{});
                }
            }

            fn advanceProgress(self: *Core, track: TrackType, loop_track: bool, written_samples: usize, sample_rate: u32) u8 {
                const duration = Songs.durationMs(track);
                if (duration == 0) return 100;

                const next = self.progress_ms +| pcmDurationMs(written_samples, sample_rate);
                self.progress_ms = if (next >= duration)
                    if (loop_track) next % duration else duration
                else
                    next;

                const value = @min(@as(u32, 100), (self.progress_ms * 100) / duration);
                return @intCast(value);
            }
        };
    };
}

fn pcmDurationMs(sample_count: usize, sample_rate: u32) u32 {
    if (sample_rate == 0) return 0;
    const value = (@as(u64, @intCast(sample_count)) * 1000) / sample_rate;
    return @intCast(@min(value, glib.std.math.maxInt(u32)));
}
