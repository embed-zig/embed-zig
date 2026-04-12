const Context = @import("../../../event/Context.zig");
const State = @import("State.zig");

pub const Show = struct {
    pub const kind = .ui_overlay_show;
    source_id: u32 = 0,
    name: [State.max_name_len]u8 = [_]u8{0} ** State.max_name_len,
    name_len: u8 = 0,
    blocking: bool = false,
    ctx: Context.Type = null,
};

pub const Hide = struct {
    pub const kind = .ui_overlay_hide;
    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const SetName = struct {
    pub const kind = .ui_overlay_set_name;
    source_id: u32 = 0,
    name: [State.max_name_len]u8 = [_]u8{0} ** State.max_name_len,
    name_len: u8 = 0,
    ctx: Context.Type = null,
};

pub const SetBlocking = struct {
    pub const kind = .ui_overlay_set_blocking;
    source_id: u32 = 0,
    value: bool,
    ctx: Context.Type = null,
};
