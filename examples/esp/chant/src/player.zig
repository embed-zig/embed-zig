const esp = @import("esp");
const assets = @import("assets.zig");
const board = @import("board.zig");
const opus_ogg = @import("opus_ogg.zig");

const log = esp.grt.std.log.scoped(.chant);
const Thread = esp.grt.std.Thread;

const ns_per_ms: u64 = 1_000_000;
const poll_interval_ms: u32 = 20;
const multi_click_ms: u32 = 320;
const long_press_ms: u32 = 700;
const volume_step: u8 = 0x10;

const ButtonAction = enum {
    none,
    play_pause,
    next,
    previous,
    volume_up,
    volume_down,
};

var button_was_pressed = false;
var button_press_ms: u32 = 0;
var button_release_ms: u32 = 0;
var button_click_count: u8 = 0;
var button_long_sent = false;
var current_track_index: usize = 0;
var playing = true;
var volume: u8 = board.default_volume;

pub fn run() noreturn {
    var current: usize = 0;

    while (true) {
        current_track_index = current;
        playing = true;
        const track = assets.tracks[current];
        refreshDisplay(track.id);
        log.info("playing {s} from {s}", .{ track.name, track.path });

        const result = opus_ogg.play(track.path, pollPlaybackControl) catch |err| recover: {
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
            .ended => {},
        }

        switch (waitBetweenLoops()) {
            .none => {},
            .next => current = nextIndex(current),
            .previous => current = previousIndex(current),
        }
    }
}

fn waitBetweenLoops() opus_ogg.ControlResult {
    var elapsed: u32 = 0;
    while (elapsed < 2000) : (elapsed += 20) {
        switch (pollControlAction()) {
            .none => {},
            .next => return .next,
            .previous => return .previous,
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

fn pollPlaybackControl() opus_ogg.ControlResult {
    while (true) {
        switch (pollControlAction()) {
            .none => {},
            .next => return .next,
            .previous => return .previous,
        }

        if (playing) return .none;
        sleepMs(poll_interval_ms);
    }
}

fn pollControlAction() opus_ogg.ControlResult {
    board.tickDisplay(poll_interval_ms);
    switch (pollInputAction()) {
        .none => return .none,
        .play_pause => {
            playing = !playing;
            refreshDisplay(assets.tracks[current_track_index].id);
            return .none;
        },
        .next => {
            playing = true;
            return .next;
        },
        .previous => {
            playing = true;
            return .previous;
        },
        .volume_up => {
            adjustVolume(.up);
            return .none;
        },
        .volume_down => {
            adjustVolume(.down);
            return .none;
        },
    }
}

fn pollInputAction() ButtonAction {
    const display_action = displayAction();
    if (display_action != .none) return display_action;
    return pollButtonAction();
}

fn displayAction() ButtonAction {
    return switch (board.takeDisplayAction()) {
        .none => .none,
        .play_pause => .play_pause,
        .next => .next,
        .previous => .previous,
        .volume_up => .volume_up,
        .volume_down => .volume_down,
    };
}

fn pollButtonAction() ButtonAction {
    const pressed = board.buttonPressedRaw();
    if (pressed) {
        if (!button_was_pressed) {
            button_was_pressed = true;
            button_press_ms = 0;
            button_long_sent = false;
            return .none;
        }

        button_press_ms += poll_interval_ms;
        if (!button_long_sent and button_press_ms >= long_press_ms) {
            button_long_sent = true;
            const action: ButtonAction = if (button_click_count == 0) .volume_up else .volume_down;
            button_click_count = 0;
            button_release_ms = 0;
            return action;
        }
        return .none;
    }

    if (button_was_pressed) {
        button_was_pressed = false;
        button_press_ms = 0;
        if (!button_long_sent) {
            button_click_count += 1;
            button_release_ms = 0;
        }
        return .none;
    }

    if (button_click_count == 0) return .none;
    button_release_ms += poll_interval_ms;
    if (button_release_ms < multi_click_ms) return .none;

    const count = button_click_count;
    button_click_count = 0;
    button_release_ms = 0;
    return switch (count) {
        1 => .play_pause,
        2 => .next,
        else => .previous,
    };
}

const VolumeDirection = enum {
    up,
    down,
};

fn adjustVolume(direction: VolumeDirection) void {
    volume = switch (direction) {
        .up => if (volume > 0xff - volume_step) 0xff else volume + volume_step,
        .down => if (volume < volume_step) 0 else volume - volume_step,
    };

    board.setVolume(volume) catch |err| {
        log.warn("volume update failed: {s}", .{@errorName(err)});
    };
    refreshDisplay(assets.tracks[current_track_index].id);
}

fn refreshDisplay(track: board.Track) void {
    board.showPlayer(track, playing, volume) catch |err| {
        log.warn("display update failed: {s}", .{@errorName(err)});
    };
}

fn sleepMs(ms: u32) void {
    Thread.sleep(@as(u64, ms) * ns_per_ms);
}
