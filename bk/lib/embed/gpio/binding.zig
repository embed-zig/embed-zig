pub const ok: c_int = 0;
pub const invalid_arg: c_int = 1;
pub const unsupported: c_int = 2;
pub const unexpected: c_int = 9;

pub const edge_rising: u32 = 0;
pub const edge_falling: u32 = 1;
pub const edge_both: u32 = 2;
pub const edge_low_level: u32 = 3;
pub const edge_high_level: u32 = 4;

pub const EventCallback = *const fn (ctx: ?*anyopaque, edge: u32, level: u32) callconv(.c) void;

pub extern fn bk_embed_gpio_read(pin: u32, level: *u32) c_int;
pub extern fn bk_embed_gpio_write(pin: u32, level: u32) c_int;
pub extern fn bk_embed_gpio_set_direction(pin: u32, direction: u32) c_int;
pub extern fn bk_embed_gpio_configure_interrupt(pin: u32, edge: u32) c_int;
pub extern fn bk_embed_gpio_set_callback(pin: u32, ctx: ?*anyopaque, cb: ?EventCallback) c_int;
pub extern fn bk_embed_gpio_clear_callback(pin: u32) c_int;
