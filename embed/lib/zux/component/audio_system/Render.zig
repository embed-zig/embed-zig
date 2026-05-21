const State = @import("State.zig");

pub fn render(state: State, audio_system: anytype) !void {
    if (state.started) {
        try audio_system.start();
    } else {
        try audio_system.stop();
    }

    try audio_system.setSpkGain(state.gain_db);

    if (state.mic_gain_count != 0) {
        try audio_system.setMicGains(state.mic_gains[0..state.mic_gain_count]);
    }
}
