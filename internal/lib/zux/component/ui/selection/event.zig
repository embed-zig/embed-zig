const Context = @import("../../../event/Context.zig");

pub const Next = struct {
    pub const kind = .ui_selection_next;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const Prev = struct {
    pub const kind = .ui_selection_prev;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const Set = struct {
    pub const kind = .ui_selection_set;

    source_id: u32 = 0,
    index: usize,
    ctx: Context.Type = null,
};

pub const Reset = struct {
    pub const kind = .ui_selection_reset;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const SetCount = struct {
    pub const kind = .ui_selection_set_count;

    source_id: u32 = 0,
    count: usize,
    ctx: Context.Type = null,
};

pub const SetLoop = struct {
    pub const kind = .ui_selection_set_loop;

    source_id: u32 = 0,
    value: bool,
    ctx: Context.Type = null,
};
