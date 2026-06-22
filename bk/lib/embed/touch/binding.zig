pub const ok: c_int = 0;
pub const no_data: c_int = 1;
pub const invalid_arg: c_int = 2;
pub const invalid_state: c_int = 3;
pub const unexpected: c_int = 9;

pub const Point = extern struct {
    x: u16,
    y: u16,
    pressed: u8,
    need_continue: u8,
};

pub extern fn bk_embed_touch_open(width: u16, height: u16, mirror: c_int) c_int;
pub extern fn bk_embed_touch_close() void;
pub extern fn bk_embed_touch_read(point: *Point) c_int;
