const esp = @import("esp");
const hal_gpio = @import("hal").gpio;

pub const Driver = struct {
    pub fn setMode(_: *Driver, pin: u8, mode: hal_gpio.Mode) hal_gpio.Error!void {
        esp.gpio.setDirection(@intCast(pin), switch (mode) {
            .input => .input,
            .output => .output,
            .input_output => .input_output,
        }) catch return error.GpioError;
    }

    pub fn setLevel(_: *Driver, pin: u8, level: hal_gpio.Level) hal_gpio.Error!void {
        esp.gpio.setLevel(@intCast(pin), @intFromEnum(level)) catch return error.GpioError;
    }

    pub fn getLevel(_: *Driver, pin: u8) hal_gpio.Error!hal_gpio.Level {
        return @enumFromInt(esp.gpio.getLevel(@intCast(pin)));
    }

    pub fn setPull(_: *Driver, pin: u8, pull: hal_gpio.Pull) hal_gpio.Error!void {
        esp.gpio.setPullMode(@intCast(pin), switch (pull) {
            .none => .floating,
            .up => .pullup_only,
            .down => .pulldown_only,
        }) catch return error.GpioError;
    }
};
