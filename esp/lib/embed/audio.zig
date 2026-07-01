pub const EspSr = @import("audio/EspSr.zig");
pub const Es8311System = @import("audio/Es8311System.zig");
pub const Es8311Es7210System = @import("audio/Es8311Es7210System.zig");

pub fn gainDbToVolume(gain_db: i8) u8 {
    const scaled: i16 = (@as(i16, gain_db) + 96) * 2;
    if (scaled <= 0) return 0;
    if (scaled >= 255) return 255;
    return @intCast(scaled);
}

pub fn applyLinearGainSaturating(samples: []i16, multiplier: i32) void {
    for (samples) |*sample| {
        const value = @as(i32, sample.*) * multiplier;
        sample.* = if (value > 32767)
            32767
        else if (value < -32768)
            -32768
        else
            @intCast(value);
    }
}
