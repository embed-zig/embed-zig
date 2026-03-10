//! 102-audio_engine — Flux state definition.
//!
//! Buttons (names match board_spec.adc_buttons fields):
//!   play     click → toggle playing
//!   set      click → next song
//!   vol_up   click → spk_gain_db += 3
//!   vol_down click → spk_gain_db -= 3
//!   mute     click → toggle muted
//!   vol_down long  → toggle audio system running

const std = @import("std");
const embed = @import("embed");
const event = embed.pkg.event;
const songs = @import("songs.zig");

const GestureCode = event.button.GestureCode;

pub const State = struct {
    spk_gain_db: i8 = 0,
    mic_gain_db: i8 = 24,
    muted: bool = false,
    playing: bool = false,
    song_index: u8 = 0,
    song_gen: u8 = 0,
    running: bool = true,
};

pub const Event = union(enum) {
    button: event.PeriphEvent,
};

pub fn reduce(state: *State, ev: Event) void {
    switch (ev) {
        .button => |b| {
            const code: u16 = b.code;
            if (code == @intFromEnum(GestureCode.click)) {
                if (std.mem.eql(u8, b.id, "play")) {
                    state.playing = !state.playing;
                } else if (std.mem.eql(u8, b.id, "set")) {
                    state.song_index = @intCast((@as(u16, state.song_index) + 1) % songs.catalog.len);
                    state.song_gen +%= 1;
                    state.playing = true;
                } else if (std.mem.eql(u8, b.id, "vol_up")) {
                    state.spk_gain_db = @min(24, state.spk_gain_db +| 3);
                } else if (std.mem.eql(u8, b.id, "vol_down")) {
                    state.spk_gain_db = @max(-12, state.spk_gain_db -| 3);
                } else if (std.mem.eql(u8, b.id, "mute")) {
                    state.muted = !state.muted;
                }
            } else if (code == @intFromEnum(GestureCode.long_press)) {
                if (std.mem.eql(u8, b.id, "vol_down")) {
                    state.running = !state.running;
                }
            }
        },
    }
}
