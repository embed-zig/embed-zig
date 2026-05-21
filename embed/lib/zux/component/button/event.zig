const glib = @import("glib");

pub const Single = struct {
    pub const kind = .raw_single_button;

    source_id: u32,
    pressed: bool,
};

pub const Grouped = struct {
    pub const kind = .raw_grouped_button;

    source_id: u32,
    button_id: ?u32,
    pressed: bool,
};

pub const Detected = struct {
    pub const kind = .button_gesture;

    pub const Value = union(enum) {
        click: u16,
        long_press: glib.time.duration.Duration,
    };

    source_id: u32,
    button_id: ?u32 = null,
    pressed_at: glib.time.instant.Time = 0,
    gesture: Value,
};
