pub const ok: c_int = 0;
pub const invalid_arg: c_int = 1;
pub const unsupported: c_int = 2;
pub const unexpected: c_int = 9;

pub extern fn bk_embed_gpio_read(pin: u32, level: *u32) c_int;
pub extern fn bk_embed_gpio_write(pin: u32, level: u32) c_int;
pub extern fn bk_embed_gpio_set_direction(pin: u32, direction: u32) c_int;
pub extern fn bk_embed_gpio_configure_interrupt(pin: u32, edge: u32) c_int;
