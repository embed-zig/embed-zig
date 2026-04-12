const Context = @import("../../../event/Context.zig");
const Item = @import("Router.zig").Item;

pub const Push = struct {
    pub const kind = .ui_route_push;

    source_id: u32 = 0,
    item: Item,
    ctx: Context.Type = null,
};

pub const Replace = struct {
    pub const kind = .ui_route_replace;

    source_id: u32 = 0,
    item: Item,
    ctx: Context.Type = null,
};

pub const Reset = struct {
    pub const kind = .ui_route_reset;

    source_id: u32 = 0,
    item: Item,
    ctx: Context.Type = null,
};

pub const Pop = struct {
    pub const kind = .ui_route_pop;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const PopToRoot = struct {
    pub const kind = .ui_route_pop_to_root;

    source_id: u32 = 0,
    ctx: Context.Type = null,
};

pub const SetTransitioning = struct {
    pub const kind = .ui_route_set_transitioning;

    source_id: u32 = 0,
    value: bool,
    ctx: Context.Type = null,
};
