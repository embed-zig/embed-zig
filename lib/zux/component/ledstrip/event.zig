const Context = @import("../../event/Context.zig");
const ledstrip = @import("ledstrip");

pub const Pixels = []const ledstrip.Color;

pub const Set = struct {
    pub const kind = .ledstrip_set;

    periph_id: u32,
    pixels: Pixels,
    brightness: u8 = 255,
    duration: u32 = 0,
    ctx: Context.Type = null,
};

pub const SetPixels = struct {
    pub const kind = .ledstrip_set_pixels;

    periph_id: u32,
    pixels: Pixels,
    brightness: u8 = 255,
    ctx: Context.Type = null,
};

pub const Flash = struct {
    pub const kind = .ledstrip_flash;

    periph_id: u32,
    pixels: Pixels,
    brightness: u8 = 255,
    duration_ns: u64,
    interval_ns: u64,
    ctx: Context.Type = null,
};

pub const Pingpong = struct {
    pub const kind = .ledstrip_pingpong;

    periph_id: u32,
    from_pixels: Pixels,
    to_pixels: Pixels,
    brightness: u8 = 255,
    duration_ns: u64,
    interval_ns: u64,
    ctx: Context.Type = null,
};

pub const Rotate = struct {
    pub const kind = .ledstrip_rotate;

    periph_id: u32,
    pixels: Pixels,
    brightness: u8 = 255,
    duration_ns: u64,
    interval_ns: u64,
    ctx: Context.Type = null,
};
