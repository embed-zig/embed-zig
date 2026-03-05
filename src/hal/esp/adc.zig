const std = @import("std");
const esp = @import("esp");
const hal_adc = @import("hal").adc;

pub const Driver = struct {
    unit: i32 = 1,
    resolution: hal_adc.Resolution = .bits_12,
    vref_mv: u16 = 1100,

    pub fn init() hal_adc.Error!Driver {
        return .{};
    }

    pub fn initConfig(unit: i32, cfg: hal_adc.Config) hal_adc.Error!Driver {
        return .{
            .unit = unit,
            .resolution = cfg.resolution,
            .vref_mv = cfg.vref_mv,
        };
    }

    pub fn read(self: *Driver, channel: u8) hal_adc.Error!u16 {
        var oneshot = esp.esp_adc.Oneshot.init(self.unit, @intCast(channel)) catch |err| return mapError(err);
        defer oneshot.deinit() catch {};

        const raw = oneshot.read() catch |err| return mapError(err);
        if (raw < 0) return error.AdcError;
        return @intCast(@min(raw, std.math.maxInt(u16)));
    }

    pub fn readMv(self: *Driver, channel: u8) hal_adc.Error!u16 {
        const raw = try self.read(channel);
        const max_raw = resolutionMaxRaw(self.resolution);
        if (max_raw == 0) return error.AdcError;
        return @intCast((@as(u32, raw) * self.vref_mv) / max_raw);
    }
};

fn resolutionMaxRaw(resolution: hal_adc.Resolution) u32 {
    const bits: u5 = @intCast(@intFromEnum(resolution));
    return (@as(u32, 1) << bits) - 1;
}

fn mapError(err: anyerror) hal_adc.Error {
    return switch (err) {
        error.InvalidArgument => error.InvalidChannel,
        else => error.AdcError,
    };
}
