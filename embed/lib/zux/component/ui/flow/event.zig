const Context = @import("../../../event/Context.zig");

pub const Direction = enum {
    forward,
    reverse,
};

pub const Move = struct {
    pub const kind = .ui_flow_move;

    source_id: u32 = 0,
    direction: Direction,
    edge_id: u32,
    ctx: Context.Type = null,
};

pub const Reset = struct {
    pub const kind = .ui_flow_reset;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};
