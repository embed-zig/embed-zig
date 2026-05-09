const esp = @import("esp");
const glib = @import("glib");

const assets = @import("../assets.zig");
const board = @import("../board.zig");
const Audio = @import("AudioSystem.zig");
const AudioSystem = Audio.Type;
const opus_ogg = @import("opus_ogg.zig");

const Player = @This();

const log = esp.grt.std.log.scoped(.chant_player);
const Thread = esp.grt.std.Thread;
const AtomicBool = esp.grt.std.atomic.Value(bool);
const CommandChannel = esp.grt.sync.Channel(Command);

const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const command_capacity: usize = 8;
const music_track_buffer_capacity: usize = 4096;
const poll_interval_ms: u32 = 20;

const Command = enum {
    play,
    pause,
    toggle_play,
    next,
    previous,
    stop,
};

system: *AudioSystem,
commands: CommandChannel,
thread: ?Thread = null,
stopping: AtomicBool = AtomicBool.init(false),
state_mu: Thread.Mutex = .{},
current_track_index: usize = 0,
playing: bool = true,
active_track_ctrl: ?Audio.TrackCtrl = null,

pub fn init(allocator: glib.std.mem.Allocator, system: *AudioSystem) !Player {
    return .{
        .system = system,
        .commands = try CommandChannel.make(allocator, command_capacity),
    };
}

pub fn deinit(self: *Player) void {
    self.stopThread();
    self.commands.close();
    self.commands.deinit();
}

pub fn startThread(self: *Player) !void {
    if (self.thread != null) return;
    self.stopping.store(false, .release);
    self.thread = try Thread.spawn(.{
        .name = "music_player",
        .stack_size = 12 * 1024,
        .allocator = thread_allocator,
        .core_id = 1,
    }, runLoop, .{self});
}

pub fn stopThread(self: *Player) void {
    self.stopping.store(true, .release);
    self.commands.close();
    self.closeActiveTrackWithError();
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn play(self: *Player) void {
    self.send(.play);
}

pub fn pause(self: *Player) void {
    self.send(.pause);
}

pub fn togglePlay(self: *Player) void {
    self.send(.toggle_play);
}

pub fn next(self: *Player) void {
    self.send(.next);
}

pub fn previous(self: *Player) void {
    self.send(.previous);
}

pub fn isPlaying(self: *Player) bool {
    self.state_mu.lock();
    defer self.state_mu.unlock();
    return self.playing;
}

pub fn currentTrack(self: *Player) assets.Track {
    self.state_mu.lock();
    defer self.state_mu.unlock();
    return assets.tracks[self.current_track_index];
}

fn runLoop(self: *Player) void {
    while (!self.stopping.load(.acquire)) {
        const track = self.currentTrack();
        log.info("playing {s} from {s}", .{ track.name, track.path });

        const handle = self.system.createTrack(.{
            .label = track.name,
            .buffer_capacity = music_track_buffer_capacity,
        }) catch |err| {
            log.err("create music track failed: {s}", .{@errorName(err)});
            sleepMs(1000);
            continue;
        };
        self.setActiveTrackCtrl(handle.ctrl);

        const result = opus_ogg.playToTrack(track.path, &handle.track, self, pollPlaybackControl) catch |err| recover: {
            if (self.stopping.load(.acquire)) break :recover @as(opus_ogg.PlayResult, .stopped);
            log.err("playback failed for {s}: {s}", .{ track.name, @errorName(err) });
            sleepMs(1000);
            break :recover @as(opus_ogg.PlayResult, .ended);
        };

        switch (result) {
            .ended => handle.ctrl.closeWrite(),
            .next, .previous, .stopped => handle.ctrl.closeWithError(),
        }
        self.clearActiveTrackCtrl();
        handle.ctrl.deinit();
        handle.track.deinit();

        switch (result) {
            .ended, .next => self.setCurrentTrackIndex(nextIndex(self.currentTrackIndex())),
            .previous => self.setCurrentTrackIndex(previousIndex(self.currentTrackIndex())),
            .stopped => break,
        }
    }
}

fn pollPlaybackControl(ctx: *anyopaque) opus_ogg.ControlResult {
    const self: *Player = @ptrCast(@alignCast(ctx));
    while (!self.stopping.load(.acquire)) {
        if (self.recvCommand()) |command| {
            switch (command) {
                .play => self.setPlaying(true),
                .pause => self.setPlaying(false),
                .toggle_play => self.setPlaying(!self.isPlaying()),
                .next => {
                    self.closeActiveTrackWithError();
                    return .next;
                },
                .previous => {
                    self.closeActiveTrackWithError();
                    return .previous;
                },
                .stop => {
                    self.closeActiveTrackWithError();
                    return .stop;
                },
            }
        }
        if (self.isPlaying()) return .none;
        sleepMs(poll_interval_ms);
    }
    return .stop;
}

fn recvCommand(self: *Player) ?Command {
    const result = self.commands.recvTimeout(0) catch return null;
    if (!result.ok) return null;
    return result.value;
}

fn send(self: *Player, command: Command) void {
    _ = self.commands.sendTimeout(command, 0) catch {};
}

fn currentTrackIndex(self: *Player) usize {
    self.state_mu.lock();
    defer self.state_mu.unlock();
    return self.current_track_index;
}

fn setCurrentTrackIndex(self: *Player, index: usize) void {
    self.state_mu.lock();
    self.current_track_index = index;
    self.playing = true;
    self.state_mu.unlock();
}

fn setPlaying(self: *Player, playing: bool) void {
    self.state_mu.lock();
    self.playing = playing;
    self.state_mu.unlock();
}

fn setActiveTrackCtrl(self: *Player, ctrl: Audio.TrackCtrl) void {
    self.state_mu.lock();
    self.active_track_ctrl = ctrl;
    self.state_mu.unlock();
}

fn clearActiveTrackCtrl(self: *Player) void {
    self.state_mu.lock();
    self.active_track_ctrl = null;
    self.state_mu.unlock();
}

fn closeActiveTrackWithError(self: *Player) void {
    self.state_mu.lock();
    const ctrl = self.active_track_ctrl;
    self.state_mu.unlock();

    if (ctrl) |active| active.closeWithError();
}

fn nextIndex(current: usize) usize {
    return (current + 1) % assets.tracks.len;
}

fn previousIndex(current: usize) usize {
    return if (current == 0) assets.tracks.len - 1 else current - 1;
}

fn sleepMs(ms: u32) void {
    Thread.sleep(@as(u64, ms) * esp.grt.time.duration.MilliSecond);
}
