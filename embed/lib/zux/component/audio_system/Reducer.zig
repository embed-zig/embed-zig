const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const State = @import("State.zig");

pub fn reduce(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;
    var next = store.get();
    _ = reduceState(&next, message);
    store.set(next);
}

pub fn reduceState(state: *State, message: Message) bool {
    switch (message.body) {
        .audio_system_start => {
            if (state.started) return false;
            state.started = true;
            return true;
        },
        .audio_system_stop => {
            if (!state.started) return false;
            state.started = false;
            return true;
        },
        .audio_system_set_gain => |event| {
            if (state.gain_db == event.gain_db) return false;
            state.gain_db = event.gain_db;
            return true;
        },
        .audio_system_inc_gain => {
            return setGain(state, increaseGain(state.*));
        },
        .audio_system_dec_gain => {
            return setGain(state, decreaseGain(state.*));
        },
        .audio_system_set_mic_gains => |event| {
            const count = @min(event.mic_gain_count, State.max_mic_gains);
            const changed = state.mic_gain_count != count or !micGainsEqual(
                state.mic_gains,
                event.mic_gains,
                count,
            );
            state.mic_gain_count = count;
            state.mic_gains = event.mic_gains;
            return changed;
        },
        else => return false,
    }
}

fn setGain(state: *State, gain_db: i8) bool {
    if (state.gain_db == gain_db) return false;
    state.gain_db = gain_db;
    return true;
}

fn increaseGain(state: State) i8 {
    if (state.gain_db >= state.max_gain_db - state.gain_step_db) return state.max_gain_db;
    return state.gain_db + state.gain_step_db;
}

fn decreaseGain(state: State) i8 {
    if (state.gain_db <= state.min_gain_db + state.gain_step_db) return state.min_gain_db;
    return state.gain_db - state.gain_step_db;
}

fn micGainsEqual(
    a: [State.max_mic_gains]?i8,
    b: [State.max_mic_gains]?i8,
    count: usize,
) bool {
    for (0..count) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}
