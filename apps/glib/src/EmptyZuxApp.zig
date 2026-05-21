pub fn make(comptime platform_grt: type) type {
    const allocator_type = platform_grt.std.mem.Allocator;
    const EmptyRegistry = struct {
        periphs: [0]u8 = .{},
        len: usize = 0,
    };

    return struct {
        pub const Allocator = allocator_type;
        pub const InitConfig = struct {
            allocator: Allocator,
        };
        pub const StartConfig = struct {};
        pub const PeriphLabel = enum { none };
        pub const registries = .{
            .adc_button = EmptyRegistry{},
            .single_button = EmptyRegistry{},
            .imu = EmptyRegistry{},
            .ledstrip = EmptyRegistry{},
            .modem = EmptyRegistry{},
            .nfc = EmptyRegistry{},
            .wifi_sta = EmptyRegistry{},
            .wifi_ap = EmptyRegistry{},
            .flow = EmptyRegistry{},
            .overlay = EmptyRegistry{},
            .router = EmptyRegistry{},
            .selection = EmptyRegistry{},
        };

        allocator: Allocator,

        pub fn init(init_config: InitConfig) !@This() {
            return .{
                .allocator = init_config.allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }

        pub fn start(self: *@This(), start_config: StartConfig) !void {
            _ = self;
            _ = start_config;
        }

        pub fn stop(self: *@This()) !void {
            _ = self;
        }

        pub fn press_single_button(self: *@This(), label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }

        pub fn release_single_button(self: *@This(), label: PeriphLabel) !void {
            _ = self;
            _ = label;
            return error.InvalidPeriphKind;
        }
    };
}
