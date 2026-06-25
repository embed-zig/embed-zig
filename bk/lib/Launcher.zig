const glib = @import("glib");

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime Board: type) type {
    const registries = ZuxAppType.ZuxApp.registries;

    comptime {
        validateSupportedRegistries(registries);
    }

    return struct {
        const Launcher = @This();

        allocator: grt.std.mem.Allocator,
        board_impl: *Board,
        app: ZuxAppType,

        pub const Config = struct {
            pipeline_tick_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
            pipeline_task_options: glib.task.Options = .{},
            poller_poll_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
            poller_task_options: glib.task.Options = .{},
        };

        pub fn init(allocator: grt.std.mem.Allocator, config: Config) !Launcher {
            const board_impl = try allocator.create(Board);
            errdefer allocator.destroy(board_impl);

            board_impl.* = try Board.init(makeBoardInitConfig(Board, allocator));
            errdefer board_impl.deinit();

            try board_impl.powerOn();
            try board_impl.start();

            const init_config = try createInitConfig(board_impl);
            var configured_init_config = init_config;
            if (@hasField(ZuxAppType.InitConfig, "pipeline_config")) {
                configured_init_config.pipeline_config.tick_interval = config.pipeline_tick_interval;
                configured_init_config.pipeline_config.task_options = config.pipeline_task_options;
            }
            if (@hasField(ZuxAppType.InitConfig, "poller_config")) {
                configured_init_config.poller_config.poll_interval = config.poller_poll_interval;
                configured_init_config.poller_config.task_options = config.poller_task_options;
            }
            return .{
                .allocator = allocator,
                .board_impl = board_impl,
                .app = try ZuxAppType.init(allocator, configured_init_config),
            };
        }

        pub fn deinit(self: *Launcher) void {
            self.app.deinit();
            self.board_impl.deinit();
            self.allocator.destroy(self.board_impl);
        }

        pub fn start(self: *Launcher) !void {
            try self.startWithConfig(.{});
        }

        pub fn startWithConfig(self: *Launcher, start_config: ZuxAppType.StartConfig) !void {
            try self.app.zux().start(start_config);
            errdefer self.app.zux().stop() catch {};

            if (comptime @hasDecl(ZuxAppType.AppHost, "start")) {
                try self.app.app().start();
            }
        }

        pub fn stop(self: *Launcher) !void {
            if (comptime @hasDecl(ZuxAppType.AppHost, "stop")) {
                self.app.app().stop();
            }
            try self.app.zux().stop();
        }

        fn createInitConfig(board: *Board) !ZuxAppType.InitConfig {
            var init_config: ZuxAppType.InitConfig = undefined;
            applyInitConfigDefaults(&init_config);

            if (comptime hasRegistry(registries, "single_button")) {
                inline for (0..registries.single_button.len) |i| {
                    const periph = registries.single_button.periphs[i];
                    if (comptime isVirtualPeriph(periph)) continue;
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.singleButton(label_name);
                }
            }

            if (comptime hasRegistry(registries, "adc_button")) {
                inline for (0..registries.adc_button.len) |i| {
                    const periph = registries.adc_button.periphs[i];
                    if (comptime isVirtualPeriph(periph)) continue;
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.groupedButton(label_name);
                }
            }

            if (comptime hasRegistry(registries, "display")) {
                inline for (0..registries.display.len) |i| {
                    const periph = registries.display.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.display(label_name);
                }
            }

            if (comptime hasRegistry(registries, "touch")) {
                inline for (0..registries.touch.len) |i| {
                    const periph = registries.touch.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.touch(label_name);
                }
            }

            if (comptime hasRegistry(registries, "bt")) {
                inline for (0..registries.bt.len) |i| {
                    const periph = registries.bt.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.btHost(label_name);
                }
            }

            if (comptime hasRegistry(registries, "audio_system")) {
                inline for (0..registries.audio_system.len) |i| {
                    const periph = registries.audio_system.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.audioSystem(label_name);
                }
            }

            if (comptime hasRegistry(registries, "switch_output")) {
                inline for (0..registries.switch_output.len) |i| {
                    const periph = registries.switch_output.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = try board.switchOutput(label_name);
                }
            }

            return init_config;
        }

        fn applyInitConfigDefaults(init_config: *ZuxAppType.InitConfig) void {
            inline for (@typeInfo(ZuxAppType.InitConfig).@"struct".fields) |field| {
                if (field.default_value_ptr) |default_value_ptr| {
                    const default_value: *const field.type = @ptrCast(@alignCast(default_value_ptr));
                    @field(init_config, field.name) = default_value.*;
                }
            }
        }
    };
}

fn validateSupportedRegistries(comptime registries: anytype) void {
    if (comptime registryLen(registries, "ledstrip") != 0) @compileError("BK launcher does not support ledstrip yet");
    if (comptime registryLen(registries, "wifi_sta") != 0) @compileError("BK launcher does not support wifi sta yet");
    if (comptime registryLen(registries, "imu") != 0) @compileError("BK launcher does not support imu yet");
    if (comptime registryLen(registries, "modem") != 0) @compileError("BK launcher does not support modem yet");
    if (comptime registryLen(registries, "nfc") != 0) @compileError("BK launcher does not support nfc yet");
    if (comptime registryLen(registries, "wifi_ap") != 0) @compileError("BK launcher does not support wifi ap yet");
}

fn hasRegistry(comptime registries: anytype, comptime name: []const u8) bool {
    return @hasField(@TypeOf(registries), name);
}

fn registryLen(comptime registries: anytype, comptime name: []const u8) usize {
    if (!hasRegistry(registries, name)) return 0;
    return @field(registries, name).len;
}

fn makeBoardInitConfig(comptime Board: type, allocator: anytype) Board.InitConfig {
    var config: Board.InitConfig = .{};
    if (@hasField(Board.InitConfig, "audio_allocator")) config.audio_allocator = allocator;
    if (@hasField(Board.InitConfig, "audio_system_config")) {
        config.audio_system_config.read_task = .{
            .min_stack_size = 16 * 1024,
        };
        config.audio_system_config.processor_task = .{
            .min_stack_size = 24 * 1024,
        };
        config.audio_system_config.write_task = .{
            .min_stack_size = 16 * 1024,
        };
    }
    if (@hasField(Board.InitConfig, "bt_allocator")) config.bt_allocator = allocator;
    return config;
}

fn labelText(comptime label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(label))) {
        .enum_literal => @tagName(label),
        .@"enum" => @tagName(label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => label[0..],
                else => @compileError("BK launcher label must be an enum literal, enum value, or []const u8"),
            },
            else => @compileError("BK launcher label must be an enum literal, enum value, or []const u8"),
        },
        .array => label[0..],
        else => @compileError("BK launcher label must be an enum literal, enum value, or []const u8"),
    };
}

fn isVirtualPeriph(comptime periph: anytype) bool {
    return @hasField(@TypeOf(periph), "input_type") and periph.input_type == .virtual;
}
