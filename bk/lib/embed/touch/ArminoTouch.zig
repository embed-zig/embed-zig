const embed = @import("embed_core");
const binding = @import("binding.zig");

const ArminoTouch = @This();

pub const Mirror = enum(c_int) {
    none = 0,
    x = 1,
    y = 2,
    xy = 3,
};

pub const Config = struct {
    width: u16 = 800,
    height: u16 = 480,
    mirror: Mirror = .none,
};

config: Config = .{},
opened: bool = false,
last_pressed: bool = false,
last_point: embed.drivers.Touch.Point = .{ .x = 0, .y = 0 },

pub fn init(config: Config) ArminoTouch {
    return .{ .config = config };
}

pub fn open(self: *ArminoTouch) !void {
    if (self.opened) return;
    try checkOpen(binding.bk_embed_touch_open(
        self.config.width,
        self.config.height,
        @intFromEnum(self.config.mirror),
    ));
    self.opened = true;
}

pub fn deinit(self: *ArminoTouch) void {
    if (!self.opened) return;
    binding.bk_embed_touch_close();
    self.opened = false;
    self.last_pressed = false;
}

pub fn read(self: *ArminoTouch, points: []embed.drivers.Touch.Point) !usize {
    if (!self.opened) try self.open();

    var raw: binding.Point = undefined;
    const rc = binding.bk_embed_touch_read(&raw);
    switch (rc) {
        binding.ok => {
            self.last_pressed = raw.pressed != 0;
            self.last_point = .{
                .id = 0,
                .x = raw.x,
                .y = raw.y,
            };
        },
        binding.no_data => {},
        binding.invalid_arg => return error.InvalidArgument,
        binding.invalid_state => return error.InvalidState,
        else => return error.Unexpected,
    }

    var drained: usize = 0;
    while (rc == binding.ok and raw.need_continue != 0 and drained < 30) {
        var next: binding.Point = undefined;
        const next_rc = binding.bk_embed_touch_read(&next);
        switch (next_rc) {
            binding.ok => {
                raw = next;
                self.last_pressed = raw.pressed != 0;
                self.last_point = .{
                    .id = 0,
                    .x = raw.x,
                    .y = raw.y,
                };
                drained += 1;
            },
            binding.no_data => break,
            binding.invalid_arg => return error.InvalidArgument,
            binding.invalid_state => return error.InvalidState,
            else => return error.Unexpected,
        }
    }

    if (!self.last_pressed) return 0;
    if (points.len == 0) return error.TooManyPoints;
    points[0] = self.last_point;
    return 1;
}

pub fn handle(self: *ArminoTouch) embed.drivers.Touch {
    return embed.drivers.Touch.init(self);
}

fn checkOpen(rc: c_int) !void {
    return switch (rc) {
        binding.ok => {},
        binding.invalid_arg => error.InvalidArgument,
        binding.invalid_state => error.InvalidState,
        else => error.Unexpected,
    };
}
