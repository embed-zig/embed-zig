const esp = @import("esp");

const assets = @import("../assets.zig");
const board = @import("../board.zig");
const opus_ogg = @import("opus_ogg.zig");
const Player = @This();

const log = esp.grt.std.log.scoped(.chant);
const Thread = esp.grt.std.Thread;

const ns_per_ms: u64 = 1_000_000;
const poll_interval_ms: u32 = 20;
const multi_click_ms: u32 = 320;
const long_press_ms: u32 = 700;
const volume_step: u8 = 0x10;
const default_volume: u8 = 0xb0;

const ButtonAction = enum {
    none,
    play_pause,
    mic,
    next,
    previous,
    volume_up,
    volume_down,
};

const PlaybackMode = enum {
    music,
    microphone,
};

button_was_pressed: bool = false,
button_press_ms: u32 = 0,
button_release_ms: u32 = 0,
button_click_count: u8 = 0,
button_long_sent: bool = false,
current_track_index: usize = 0,
playback_mode: PlaybackMode = .music,
playing: bool = true,
volume: u8 = default_volume,

pub fn init() Player {
    return .{};
}

pub fn run(self: *Player) noreturn {
    var current: usize = 0;

    while (true) {
        self.current_track_index = current;
        self.playback_mode = .music;
        self.playing = true;
        const track = assets.tracks[current];
        self.refreshDisplay(track.id);
        log.info("playing {s} from {s}", .{ track.name, track.path });

        const result = opus_ogg.play(track.path, self, pollPlaybackControl) catch |err| recover: {
            log.err("playback failed for {s}: {s}", .{ track.name, @errorName(err) });
            sleepMs(1000);
            break :recover .ended;
        };

        switch (result) {
            .next => {
                current = nextIndex(current);
                continue;
            },
            .previous => {
                current = previousIndex(current);
                continue;
            },
            .microphone => {
                switch (self.runMicrophoneMode()) {
                    .none => {},
                    .next => current = nextIndex(current),
                    .previous => current = previousIndex(current),
                    .microphone => {},
                }
                continue;
            },
            .ended => {},
        }

        switch (self.waitBetweenLoops()) {
            .none => {},
            .next => current = nextIndex(current),
            .previous => current = previousIndex(current),
            .microphone => switch (self.runMicrophoneMode()) {
                .none => {},
                .next => current = nextIndex(current),
                .previous => current = previousIndex(current),
                .microphone => {},
            },
        }
    }
}

fn waitBetweenLoops(self: *Player) opus_ogg.ControlResult {
    var elapsed: u32 = 0;
    while (elapsed < 2000) : (elapsed += 20) {
        switch (self.pollControlAction()) {
            .none => {},
            .next => return .next,
            .previous => return .previous,
            .microphone => return .microphone,
        }
        sleepMs(poll_interval_ms);
    }
    return .none;
}

fn nextIndex(current: usize) usize {
    return (current + 1) % assets.tracks.len;
}

fn previousIndex(current: usize) usize {
    return if (current == 0) assets.tracks.len - 1 else current - 1;
}

fn pollPlaybackControl(ctx: *anyopaque) opus_ogg.ControlResult {
    const self: *Player = @ptrCast(@alignCast(ctx));
    while (true) {
        switch (self.pollControlAction()) {
            .none => {},
            .next => return .next,
            .previous => return .previous,
            .microphone => return .microphone,
        }

        if (self.playing) return .none;
        sleepMs(poll_interval_ms);
    }
}

fn pollControlAction(self: *Player) opus_ogg.ControlResult {
    board.tickDisplay(poll_interval_ms);
    switch (self.pollInputAction()) {
        .none => return .none,
        .play_pause => {
            self.playing = !self.playing;
            self.refreshDisplay(assets.tracks[self.current_track_index].id);
            return .none;
        },
        .next => {
            self.playing = true;
            return .next;
        },
        .previous => {
            self.playing = true;
            return .previous;
        },
        .mic => {
            self.playing = false;
            return .microphone;
        },
        .volume_up => {
            self.adjustVolume(.up);
            return .none;
        },
        .volume_down => {
            self.adjustVolume(.down);
            return .none;
        },
    }
}

fn pollInputAction(self: *Player) ButtonAction {
    const display_action = displayAction();
    if (display_action != .none) return display_action;
    return self.pollButtonAction();
}

fn displayAction() ButtonAction {
    return switch (board.takeDisplayAction()) {
        .none => .none,
        .play_pause => .play_pause,
        .mic => .mic,
        .next => .next,
        .previous => .previous,
        .volume_up => .volume_up,
        .volume_down => .volume_down,
    };
}

fn pollButtonAction(self: *Player) ButtonAction {
    const pressed = board.buttonPressedRaw();
    if (pressed) {
        if (!self.button_was_pressed) {
            self.button_was_pressed = true;
            self.button_press_ms = 0;
            self.button_long_sent = false;
            return .none;
        }

        self.button_press_ms += poll_interval_ms;
        if (!self.button_long_sent and self.button_press_ms >= long_press_ms) {
            self.button_long_sent = true;
            const action: ButtonAction = if (self.button_click_count == 0) .volume_up else .volume_down;
            self.button_click_count = 0;
            self.button_release_ms = 0;
            return action;
        }
        return .none;
    }

    if (self.button_was_pressed) {
        self.button_was_pressed = false;
        self.button_press_ms = 0;
        if (!self.button_long_sent) {
            self.button_click_count += 1;
            self.button_release_ms = 0;
        }
        return .none;
    }

    if (self.button_click_count == 0) return .none;
    self.button_release_ms += poll_interval_ms;
    if (self.button_release_ms < multi_click_ms) return .none;

    const count = self.button_click_count;
    self.button_click_count = 0;
    self.button_release_ms = 0;
    return switch (count) {
        1 => .play_pause,
        2 => .next,
        else => .previous,
    };
}

fn runMicrophoneMode(self: *Player) opus_ogg.ControlResult {
    self.playback_mode = .microphone;
    self.playing = false;
    self.refreshDisplay(assets.tracks[self.current_track_index].id);
    board.startMicrophoneStream() catch |err| {
        log.warn("mic stream start failed: {s}", .{@errorName(err)});
        self.playback_mode = .music;
        self.playing = true;
        self.refreshDisplay(assets.tracks[self.current_track_index].id);
        return .none;
    };
    defer board.stopMicrophoneStream();

    while (true) {
        board.tickDisplay(poll_interval_ms);
        switch (self.pollInputAction()) {
            .none => {},
            .play_pause, .mic => {
                self.playback_mode = .music;
                self.playing = true;
                self.refreshDisplay(assets.tracks[self.current_track_index].id);
                return .none;
            },
            .next => {
                self.playback_mode = .music;
                self.playing = true;
                return .next;
            },
            .previous => {
                self.playback_mode = .music;
                self.playing = true;
                return .previous;
            },
            .volume_up => self.adjustVolume(.up),
            .volume_down => self.adjustVolume(.down),
        }

        board.processMicrophoneFrame() catch |err| {
            log.warn("mic stream frame failed: {s}", .{@errorName(err)});
            sleepMs(poll_interval_ms);
        };
    }
}

const VolumeDirection = enum {
    up,
    down,
};

fn adjustVolume(self: *Player, direction: VolumeDirection) void {
    self.volume = switch (direction) {
        .up => if (self.volume > 0xff - volume_step) 0xff else self.volume + volume_step,
        .down => if (self.volume < volume_step) 0 else self.volume - volume_step,
    };

    board.setVolume(self.volume) catch |err| {
        log.warn("volume update failed: {s}", .{@errorName(err)});
    };
    self.refreshDisplay(assets.tracks[self.current_track_index].id);
}

fn refreshDisplay(self: *Player, track: board.Track) void {
    const mode: board.Mode = switch (self.playback_mode) {
        .music => .music,
        .microphone => .microphone,
    };
    board.showPlayer(track, mode, self.playing, self.volume) catch |err| {
        log.warn("display update failed: {s}", .{@errorName(err)});
    };
}

fn sleepMs(ms: u32) void {
    Thread.sleep(@as(u64, ms) * ns_per_ms);
}
