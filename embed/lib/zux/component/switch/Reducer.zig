const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const state_mod = @import("state.zig");

const SwitchState = state_mod.Switch;
const PwmState = state_mod.Pwm;

pub fn reduceSwitch(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;
    var next = store.get();
    _ = reduceSwitchState(&next, message);
    store.set(next);
}

pub fn reduceSwitchState(state: *SwitchState, message: Message) bool {
    switch (message.body) {
        .switch_set => |event| {
            if (state.enabled == event.enabled) return false;
            state.enabled = event.enabled;
            return true;
        },
        else => return false,
    }
}

pub fn reducePwm(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;
    var next = store.get();
    _ = reducePwmState(&next, message);
    store.set(next);
}

pub fn reducePwmState(state: *PwmState, message: Message) bool {
    switch (message.body) {
        .pwm_set => |event| {
            const changed = state.enabled != event.enabled or
                state.frequency_hz != event.frequency_hz or
                state.duty.numerator != event.duty.numerator or
                state.duty.denominator != event.duty.denominator;
            state.enabled = event.enabled;
            state.frequency_hz = event.frequency_hz;
            state.duty = event.duty;
            return changed;
        },
        else => return false,
    }
}
