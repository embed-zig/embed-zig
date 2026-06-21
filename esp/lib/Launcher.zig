const glib = @import("glib");
const grt_mod = @import("esp_grt").runtime;

const grt = glib.runtime.make(grt_mod);
const log = grt.std.log.scoped(.esp_launcher);
const launcher_mod = @This();

pub const Config = struct {
    pipeline_tick_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
    pipeline_task_options: glib.task.Options = .{ .min_stack_size = 16 * 1024 },
    poller_poll_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
    poller_task_options: glib.task.Options = .{ .min_stack_size = 8 * 1024 },
};

pub fn make(
    comptime ZuxAppType: type,
    comptime Board: type,
) type {
    const registries = ZuxAppType.ZuxApp.registries;

    comptime {
        validateSupportedRegistries(registries);
    }

    return struct {
        const Launcher = @This();

        allocator: grt.std.mem.Allocator,
        board_impl: *Board,
        app: ZuxAppType,

        pub fn init(allocator: grt.std.mem.Allocator, config: launcher_mod.Config) !Launcher {
            const board_impl = try initBoard(allocator, config);
            errdefer {
                board_impl.deinit();
                allocator.destroy(board_impl);
            }

            return initWithBoard(allocator, board_impl, config);
        }

        pub fn initBoard(allocator: grt.std.mem.Allocator, config: launcher_mod.Config) !*Board {
            const board_impl = try allocator.create(Board);
            errdefer allocator.destroy(board_impl);

            board_impl.* = try Board.init(makeBoardInitConfig(Board, allocator, config));
            errdefer board_impl.deinit();

            if (@hasDecl(Board, "initNvs")) {
                try board_impl.initNvs();
            }
            try board_impl.powerOn();
            try board_impl.start();

            return board_impl;
        }

        pub fn initCacheSensitivePeriphs(board_impl: *Board) !void {
            inline for (0..registries.display.len) |i| {
                const periph = registries.display.periphs[i];
                const label_name = comptime labelText(periph.label);
                _ = board_impl.display(label_name) catch |err| {
                    log.err("board missing display component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.bt.len) |i| {
                const periph = registries.bt.periphs[i];
                const label_name = comptime labelText(periph.label);
                _ = board_impl.btHost(label_name) catch |err| {
                    log.err("board missing bt host component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.wifi_sta.len) |i| {
                const periph = registries.wifi_sta.periphs[i];
                const label_name = comptime labelText(periph.label);
                _ = board_impl.wifiSta(label_name) catch |err| {
                    log.err("board missing wifi sta component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }
        }

        pub fn initWithBoard(allocator: grt.std.mem.Allocator, board_impl: *Board, config: launcher_mod.Config) !Launcher {
            const init_config = try createInitConfig(board_impl);
            var configured_init_config = init_config;
            configured_init_config.pipeline_config.tick_interval = config.pipeline_tick_interval;
            configured_init_config.pipeline_config.task_options = config.pipeline_task_options;
            configured_init_config.poller_config.poll_interval = config.poller_poll_interval;
            configured_init_config.poller_config.task_options = config.poller_task_options;

            log.info("zux app init before", .{});
            const app = try ZuxAppType.init(allocator, configured_init_config);
            log.info("zux app init after", .{});

            return .{
                .allocator = allocator,
                .board_impl = board_impl,
                .app = app,
            };
        }

        pub fn deinit(self: *Launcher) void {
            self.app.deinit();
            self.board_impl.deinit();
            self.allocator.destroy(self.board_impl);
        }

        pub fn start(self: *Launcher) !void {
            try self.app.zux().start(.{});
            errdefer self.app.zux().stop() catch {};

            if (comptime @hasDecl(ZuxAppType.AppHost, "start")) {
                try self.app.app().start();
            }

            log.info("{s} running on {s} board", .{
                comptime appTitle(ZuxAppType.AppHost),
                comptime boardName(Board),
            });
        }

        pub fn stop(self: *Launcher) !void {
            if (comptime @hasDecl(ZuxAppType.AppHost, "stop")) {
                self.app.app().stop();
            }
            try self.app.zux().stop();
        }

        fn createInitConfig(board: *Board) !ZuxAppType.InitConfig {
            var init_config: ZuxAppType.InitConfig = undefined;
            inline for (@typeInfo(ZuxAppType.InitConfig).@"struct".fields) |field| {
                if (field.default_value_ptr) |default_value_ptr| {
                    const default_value: *const field.type = @ptrCast(@alignCast(default_value_ptr));
                    @field(init_config, field.name) = default_value.*;
                }
            }
            if (@hasField(ZuxAppType.InitConfig, "custom_pipeline_node")) {
                init_config.custom_pipeline_node = null;
            }

            inline for (0..registries.display.len) |i| {
                const periph = registries.display.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.display(label_name) catch |err| {
                    log.err("board missing display component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.bt.len) |i| {
                const periph = registries.bt.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.btHost(label_name) catch |err| {
                    log.err("board missing bt host component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.wifi_sta.len) |i| {
                const periph = registries.wifi_sta.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.wifiSta(label_name) catch |err| {
                    log.err("board missing wifi sta component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.audio_system.len) |i| {
                const periph = registries.audio_system.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.audioSystem(label_name) catch |err| {
                    log.err("board missing audio system component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.single_button.len) |i| {
                const periph = registries.single_button.periphs[i];
                if (comptime isVirtualPeriph(periph)) continue;
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.singleButton(label_name) catch |err| {
                    log.err("board missing single button component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.adc_button.len) |i| {
                const periph = registries.adc_button.periphs[i];
                if (comptime isVirtualPeriph(periph)) continue;
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.groupedButton(label_name) catch |err| {
                    log.err("board missing grouped button component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.ledstrip.len) |i| {
                const periph = registries.ledstrip.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.ledStrip(label_name) catch |err| {
                    log.err("board missing led strip component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.touch.len) |i| {
                const periph = registries.touch.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.touch(label_name) catch |err| {
                    log.err("board missing touch component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.nfc.len) |i| {
                const periph = registries.nfc.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.nfc(label_name) catch |err| {
                    log.err("board missing nfc component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            inline for (0..registries.modem.len) |i| {
                const periph = registries.modem.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.modem(label_name) catch |err| {
                    log.err("board missing modem component '{s}': {s}", .{ label_name, @errorName(err) });
                    return err;
                };
            }

            log.info("zux init config created", .{});
            return init_config;
        }
    };
}

fn validateSupportedRegistries(comptime registries: anytype) void {
    if (registries.imu.len != 0) @compileError("ESP launcher does not support imu yet");
    if (registries.wifi_ap.len != 0) @compileError("ESP launcher does not support wifi ap yet");
}

fn makeBoardInitConfig(comptime Board: type, allocator: grt.std.mem.Allocator, _: Config) Board.InitConfig {
    var config: Board.InitConfig = .{};
    if (@hasField(Board.InitConfig, "audio_allocator")) config.audio_allocator = allocator;
    if (@hasField(Board.InitConfig, "audio_system_config")) config.audio_system_config = .{};
    if (@hasField(Board.InitConfig, "bt_allocator")) config.bt_allocator = allocator;
    return config;
}

fn appTitle(comptime AppHost: type) []const u8 {
    if (@hasDecl(AppHost, "title")) {
        return AppHost.title;
    }
    return "selected app";
}

fn boardName(comptime Board: type) []const u8 {
    if (@hasDecl(Board, "metadata")) {
        return Board.metadata.name;
    }
    return "selected";
}

fn labelText(comptime label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(label))) {
        .enum_literal => @tagName(label),
        .@"enum" => @tagName(label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => label[0..],
                else => @compileError("ESP launcher label must be an enum literal, enum value, or []const u8"),
            },
            else => @compileError("ESP launcher label must be an enum literal, enum value, or []const u8"),
        },
        .array => label[0..],
        else => @compileError("ESP launcher label must be an enum literal, enum value, or []const u8"),
    };
}

fn isVirtualPeriph(comptime periph: anytype) bool {
    return @hasField(@TypeOf(periph), "input_type") and periph.input_type == .virtual;
}
