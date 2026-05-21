pub const Raw = struct {
    pub const kind = .raw_touch;

    source_id: u32,
    pressed: bool,
    point_count: usize = 0,
    id: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,
    pressure: ?u16 = null,
};
