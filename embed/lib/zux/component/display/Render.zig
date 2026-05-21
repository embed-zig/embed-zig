const drivers = @import("drivers");
const State = @import("State.zig");

pub fn render(state: State, display: drivers.Display) drivers.Display.Error!void {
    try display.setEnabled(state.enabled);
    try display.setBrightness(state.brightness);
}
