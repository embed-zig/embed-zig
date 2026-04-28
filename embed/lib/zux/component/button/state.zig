const glib = @import("glib");

pub const Single = struct {
    source_id: u32 = 0,
    pressed: bool = false,
};

pub const Grouped = struct {
    source_id: u32 = 0,
    button_id: ?u32 = null,
    pressed: bool = false,
};

pub const Detected = struct {
    source_id: u32 = 0,
    button_id: ?u32 = null,
    gesture_kind: ?enum {
        click,
        long_press,
    } = null,
    click_count: u16 = 0,
    long_press: glib.time.duration.Duration = 0,
};
