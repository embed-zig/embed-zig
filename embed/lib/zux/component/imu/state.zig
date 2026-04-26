const State = @This();

pub const Motion = enum {
    shake,
    tilt,
    flip,
    free_fall,
};

source_id: u32 = 0,
motion: ?Motion = null,
