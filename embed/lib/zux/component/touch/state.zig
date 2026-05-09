const drivers = @import("drivers");

const State = @This();

pub const Point = drivers.Touch.Point;

source_id: u32 = 0,
pressed: bool = false,
point_count: usize = 0,
primary: ?Point = null,
last_primary: ?Point = null,
