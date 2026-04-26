const Context = @import("../../event/Context.zig");

pub const Single = struct {
    pub const kind = .raw_single_button;

    source_id: u32,
    pressed: bool,
    ctx: Context.Type = null,
};

pub const Grouped = struct {
    pub const kind = .raw_grouped_button;

    source_id: u32,
    button_id: ?u32,
    pressed: bool,
    ctx: Context.Type = null,
};

pub const Detected = struct {
    pub const kind = .button_gesture;

    pub const Value = union(enum) {
        click: u16,
        long_press_ns: u64,
    };

    source_id: u32,
    button_id: ?u32 = null,
    gesture: Value,
    ctx: Context.Type = null,
};
