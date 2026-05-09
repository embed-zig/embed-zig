const glib = @import("glib");
const grt_mod = @import("esp_grt").runtime;

const grt = glib.runtime.make(grt_mod);
const log = grt.std.log.scoped(.esp_launcher);
const launcher_mod = @This();

pub const Config = struct {
    pipeline_tick_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
    pipeline_spawn_config: grt.std.Thread.SpawnConfig = .{},
    poller_poll_interval: grt.time.duration.Duration = 10 * grt.time.duration.MilliSecond,
    poller_spawn_config: grt.std.Thread.SpawnConfig = .{},
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
            const board_impl = try allocator.create(Board);
            errdefer allocator.destroy(board_impl);

            board_impl.* = try Board.init(.{});
            errdefer board_impl.deinit();

            try board_impl.powerOn();
            try board_impl.start();

            const init_config = try createInitConfig(board_impl);
            var configured_init_config = init_config;
            configured_init_config.pipeline_config.tick_interval = config.pipeline_tick_interval;
            configured_init_config.pipeline_config.spawn_config = config.pipeline_spawn_config;
            configured_init_config.poller_config.poll_interval = config.poller_poll_interval;
            configured_init_config.poller_config.spawn_config = config.poller_spawn_config;

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
            try self.app.zux().start(.{});

            log.info("{s} running on {s} board", .{
                comptime appTitle(ZuxAppType.AppHost),
                comptime boardName(Board),
            });
        }

        pub fn stop(self: *Launcher) !void {
            try self.app.zux().stop();
        }

        fn createInitConfig(board: *Board) !ZuxAppType.InitConfig {
            var init_config: ZuxAppType.InitConfig = undefined;
            if (@hasField(ZuxAppType.InitConfig, "custom_pipeline_node")) {
                init_config.custom_pipeline_node = null;
            }

            inline for (0..registries.gpio_button.len) |i| {
                const periph = registries.gpio_button.periphs[i];
                const label_name = comptime labelText(periph.label);
                @field(init_config, label_name) = board.singleButton(label_name) catch |err| {
                    log.err("board missing single button component '{s}': {s}", .{ label_name, @errorName(err) });
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

            return init_config;
        }
    };
}

fn validateSupportedRegistries(comptime registries: anytype) void {
    if (registries.adc_button.len != 0) @compileError("ESP launcher does not support grouped buttons yet");
    if (registries.imu.len != 0) @compileError("ESP launcher does not support imu yet");
    if (registries.modem.len != 0) @compileError("ESP launcher does not support modem yet");
    if (registries.nfc.len != 0) @compileError("ESP launcher does not support nfc yet");
    if (registries.wifi_sta.len != 0) @compileError("ESP launcher does not support wifi sta yet");
    if (registries.wifi_ap.len != 0) @compileError("ESP launcher does not support wifi ap yet");
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
