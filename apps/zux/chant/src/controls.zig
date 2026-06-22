pub const Id = enum(u32) {
    up = 0,
    previous = 1,
    next = 2,
    down = 3,
    volume_up = 4,
    volume_down = 5,
    front = 6,
};

pub fn id(action: Id) u32 {
    return @intFromEnum(action);
}

pub fn fromButtonId(button_id: ?u32) ?Id {
    const value = button_id orelse return null;
    return switch (value) {
        id(.up) => .up,
        id(.previous) => .previous,
        id(.next) => .next,
        id(.down) => .down,
        id(.volume_up) => .volume_up,
        id(.volume_down) => .volume_down,
        id(.front) => .front,
        else => null,
    };
}
