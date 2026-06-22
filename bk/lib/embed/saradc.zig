const bk = @import("../bk.zig");
const embed = @import("embed_core");

pub const Error = embed.drivers.Adc.Error;

pub const Channel = enum {
    sdmadc4,
    adc14,
};

pub const ButtonRange = struct {
    id: u32,
    min_mv: u32,
    max_mv: u32,

    fn contains(self: ButtonRange, voltage_mv: u32) bool {
        return voltage_mv >= self.min_mv and voltage_mv <= self.max_mv;
    }
};

pub const ButtonGroupConfig = struct {
    channel: Channel = .sdmadc4,
    ranges: []const ButtonRange,
    stable_sample_count: u8 = 2,
};

pub const ButtonConfig = struct {
    channel: Channel = .sdmadc4,
    min_mv: u32,
    max_mv: u32,
    stable_sample_count: u8 = 2,
};

pub const Sdmadc4 = struct {
    initialized: bool = false,
    last_voltage_mv: u32 = 0,

    pub fn init(self: *Sdmadc4) !void {
        if (self.initialized) return;
        if (bk_embed_adc4_init() != 0) return error.HwError;
        self.initialized = true;
    }

    pub fn readVoltage(self: *Sdmadc4) Error!f32 {
        const voltage_mv = try self.readVoltageMv();
        return @as(f32, @floatFromInt(voltage_mv)) / 1000.0;
    }

    pub fn readVoltageMv(self: *Sdmadc4) Error!u32 {
        if (!self.initialized) try self.init();

        var voltage_mv: u32 = 0;
        if (bk_embed_adc4_read_voltage_mv(&voltage_mv) != 0) {
            return error.HwError;
        }
        self.last_voltage_mv = voltage_mv;
        return voltage_mv;
    }

    pub fn handle(self: *Sdmadc4) embed.drivers.Adc {
        return embed.drivers.Adc.init(self);
    }
};

pub const Adc14 = struct {
    initialized: bool = false,
    last_voltage_mv: u32 = 0,

    pub fn init(self: *Adc14) !void {
        if (self.initialized) return;
        if (bk_embed_saradc14_init() != 0) return error.HwError;
        self.initialized = true;
    }

    pub fn readVoltage(self: *Adc14) Error!f32 {
        const voltage_mv = try self.readVoltageMv();
        return @as(f32, @floatFromInt(voltage_mv)) / 1000.0;
    }

    pub fn readVoltageMv(self: *Adc14) Error!u32 {
        if (!self.initialized) try self.init();

        var voltage_mv: u32 = 0;
        if (bk_embed_saradc14_read_voltage_mv(&voltage_mv) != 0) {
            return error.HwError;
        }
        self.last_voltage_mv = voltage_mv;
        return voltage_mv;
    }

    pub fn handle(self: *Adc14) embed.drivers.Adc {
        return embed.drivers.Adc.init(self);
    }
};

pub fn ButtonGroup(comptime config: ButtonGroupConfig) type {
    return struct {
        const Self = @This();

        channel: ChannelImpl(config.channel) = .{},
        candidate_button_id: ?u32 = null,
        candidate_count: u8 = 0,
        debounced_button_id: ?u32 = null,

        pub fn init(self: *Self) !void {
            try self.channel.init();
        }

        pub fn pressedButtonId(self: *Self) Error!?u32 {
            const voltage_mv = try self.channel.readVoltageMv();
            const raw_button_id = matchButton(voltage_mv);

            if (self.candidate_button_id == raw_button_id) {
                if (self.candidate_count < config.stable_sample_count) {
                    self.candidate_count += 1;
                }
            } else {
                self.candidate_button_id = raw_button_id;
                self.candidate_count = 1;
            }

            if (self.candidate_count >= config.stable_sample_count) {
                self.debounced_button_id = raw_button_id;
            }

            return self.debounced_button_id;
        }

        pub fn pressedButton(self: *Self) Error!?u32 {
            return self.pressedButtonId();
        }

        pub fn handle(self: *Self) embed.drivers.button.Grouped {
            return embed.drivers.button.Grouped.fromAdcButton(self);
        }

        fn matchButton(voltage_mv: u32) ?u32 {
            for (config.ranges) |range| {
                if (range.contains(voltage_mv)) return range.id;
            }
            return null;
        }
    };
}

pub fn Button(comptime config: ButtonConfig) type {
    return struct {
        const Self = @This();

        channel: ChannelImpl(config.channel) = .{},
        candidate_pressed: ?bool = null,
        candidate_count: u8 = 0,
        debounced_pressed: bool = false,

        pub fn init(self: *Self) !void {
            try self.channel.init();
        }

        pub fn isPressed(self: *Self) Error!bool {
            const voltage_mv = try self.channel.readVoltageMv();
            const raw_pressed = voltage_mv >= config.min_mv and voltage_mv <= config.max_mv;

            if (self.candidate_pressed == raw_pressed) {
                if (self.candidate_count < config.stable_sample_count) {
                    self.candidate_count += 1;
                }
            } else {
                self.candidate_pressed = raw_pressed;
                self.candidate_count = 1;
            }

            if (self.candidate_count >= config.stable_sample_count) {
                self.debounced_pressed = raw_pressed;
            }

            return self.debounced_pressed;
        }

        pub fn handle(self: *Self) embed.drivers.button.Single {
            return embed.drivers.button.Single.init(Self, self);
        }
    };
}

fn ChannelImpl(comptime channel: Channel) type {
    return switch (channel) {
        .sdmadc4 => Sdmadc4,
        .adc14 => Adc14,
    };
}

extern fn bk_embed_adc4_init() c_int;
extern fn bk_embed_adc4_read_voltage_mv(voltage_mv: *u32) c_int;
extern fn bk_embed_saradc14_init() c_int;
extern fn bk_embed_saradc14_read_voltage_mv(voltage_mv: *u32) c_int;
