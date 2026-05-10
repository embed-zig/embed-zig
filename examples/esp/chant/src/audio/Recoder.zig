const esp = @import("esp");
const glib = @import("glib");

const board = @import("../board.zig");
const Audio = @import("AudioSystem.zig");
const AudioSystem = Audio.Type;

const Recoder = @This();

const log = esp.grt.std.log.scoped(.chant_recoder);
const Thread = esp.grt.std.Thread;
const AtomicBool = esp.grt.std.atomic.Value(bool);

const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const mic_frame_samples_per_channel = AudioSystem.frame_samples_per_channel;
const mic_track_buffer_capacity = mic_frame_samples_per_channel * 2;
const poll_interval_ms: u32 = 2;

system: *AudioSystem,
state_mu: Thread.Mutex = .{},
active_track: ?Audio.TrackHandle = null,
thread: ?Thread = null,
stopping: AtomicBool = AtomicBool.init(false),
active: AtomicBool = AtomicBool.init(false),

pub fn init(_: glib.std.mem.Allocator, system: *AudioSystem) !Recoder {
    return .{
        .system = system,
    };
}

pub fn deinit(self: *Recoder) void {
    self.stopThread();
}

pub fn startThread(self: *Recoder) !void {
    if (self.thread != null) return;
    self.stopping.store(false, .release);
    self.thread = try Thread.spawn(.{
        .name = "mic_recoder",
        .stack_size = 8 * 1024,
        .allocator = thread_allocator,
        .core_id = 1,
    }, runLoop, .{self});
}

pub fn stopThread(self: *Recoder) void {
    self.stopping.store(true, .release);
    self.stop();
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn start(self: *Recoder) void {
    self.system.discardReadBuffer();
    self.state_mu.lock();
    defer self.state_mu.unlock();

    if (self.active_track != null) {
        self.active.store(true, .release);
        return;
    }

    self.active_track = self.system.createTrack(.{
        .label = "mic",
        .buffer_capacity = mic_track_buffer_capacity,
    }) catch |err| {
        log.warn("mic track create failed: {s}", .{@errorName(err)});
        return;
    };
    self.active.store(true, .release);
}

pub fn stop(self: *Recoder) void {
    self.active.store(false, .release);
    self.state_mu.lock();
    const handle = self.active_track;
    self.active_track = null;
    self.state_mu.unlock();

    if (handle) |active_handle| {
        active_handle.ctrl.closeWithError();
        active_handle.ctrl.deinit();
        active_handle.track.deinit();
    }
}

pub fn isActive(self: *Recoder) bool {
    return self.active.load(.acquire);
}

fn runLoop(self: *Recoder) void {
    var processed: [mic_frame_samples_per_channel]i16 = undefined;

    while (!self.stopping.load(.acquire)) {
        const n = self.system.read(processed[0..]) catch |err| switch (err) {
            error.WouldBlock => {
                sleepMs(poll_interval_ms);
                continue;
            },
            else => {
                log.warn("audio system mic read failed: {s}", .{@errorName(err)});
                sleepMs(poll_interval_ms);
                continue;
            },
        };
        if (n == 0) continue;
        if (!self.active.load(.acquire)) continue;

        self.state_mu.lock();
        if (self.active_track) |handle| {
            handle.track.write(.{ .rate = board.audio_sample_rate, .channels = .mono }, processed[0..n]) catch |err| {
                log.warn("mic track write failed: {s}", .{@errorName(err)});
                sleepMs(poll_interval_ms);
            };
        }
        self.state_mu.unlock();
    }
}

fn sleepMs(ms: u32) void {
    Thread.sleep(@as(u64, ms) * esp.grt.time.duration.MilliSecond);
}
