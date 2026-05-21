const drivers = @import("drivers");
const state_mod = @import("state.zig");

pub fn renderSwitch(state: state_mod.Switch, output: drivers.Switch) drivers.Switch.Error!void {
    try output.set(state.enabled);
}

pub fn renderPwm(state: state_mod.Pwm, pwm: drivers.Pwm) drivers.Pwm.Error!void {
    try pwm.setFrequencyHz(state.frequency_hz);
    try pwm.setDuty(state.duty);
    if (state.enabled) {
        try pwm.enable();
    } else {
        try pwm.disable();
    }
}
