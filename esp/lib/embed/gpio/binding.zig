pub const ok: c_int = 0;

pub const edge_rising: u32 = 0;
pub const edge_falling: u32 = 1;
pub const edge_both: u32 = 2;
pub const edge_low_level: u32 = 3;
pub const edge_high_level: u32 = 4;

pub const EventCallback = *const fn (ctx: ?*anyopaque, edge: u32, level: u32) callconv(.c) void;

pub extern fn esp_embed_gpio_read(pin: c_int, level: *u32) c_int;
pub extern fn esp_embed_gpio_write(pin: c_int, level: u32) c_int;
pub extern fn esp_embed_gpio_set_direction(pin: c_int, direction: u32) c_int;
pub extern fn esp_embed_gpio_configure_interrupt(pin: c_int, edge: u32) c_int;
pub extern fn esp_embed_gpio_set_callback(pin: c_int, ctx: ?*anyopaque, cb: ?EventCallback) c_int;
pub extern fn esp_embed_gpio_clear_callback(pin: c_int) c_int;
