const glib = @import("glib");
const gstd = @import("gstd");
const desktop_http = @import("../http.zig");
const embed = @import("embed");

pub fn make(comptime ZuxApp: type) type {
    const ZuxServer = desktop_http.ZuxServer.make(ZuxApp);

    return struct {
        const App = @This();

        address: desktop_http.AddrPort,
        server: ZuxServer,

        pub const Options = struct {
            address: desktop_http.AddrPort,
            assets_dir: ?[]const u8 = null,
        };

        pub fn init(allocator: gstd.runtime.std.mem.Allocator, options: Options) !App {
            return .{
                .address = options.address,
                .server = try ZuxServer.init(allocator, .{
                    .assets_dir = options.assets_dir,
                }),
            };
        }

        pub fn deinit(self: *App) void {
            self.server.deinit();
            self.* = undefined;
        }

        pub fn serve(self: *App, listener: desktop_http.Listener) !void {
            try self.server.serve(listener);
        }

        pub fn listenAndServe(self: *App) !void {
            try self.server.listenAndServe(self.address);
        }

        pub fn close(self: *App) void {
            self.server.close();
        }
    };
}

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = runner;
            _ = allocator;

            const EmptyRegistry = struct {
                periphs: [0]u8 = .{},
                len: usize = 0,
            };
            const FakeZuxApp = struct {
                pub const PeriphLabel = enum { button, strip };
                pub const StartConfig = struct {
                    ticker: ?union(enum) {
                        manual,
                    } = .manual,
                };
                pub const InitConfig = struct {
                    allocator: std.mem.Allocator,
                    button: embed.drivers.button.Single,
                    strip: embed.ledstrip.LedStrip,
                };
                pub const registries = .{
                    .adc_button = EmptyRegistry{},
                    .gpio_button = struct {
                        pub const Periph = struct {
                            label: @Type(.enum_literal),
                            id: u32,
                            control_type: type,
                        };

                        periphs: [1]Periph = .{
                            .{ .label = .button, .id = 1, .control_type = embed.drivers.button.Single },
                        },
                        len: usize = 1,
                    }{},
                    .imu = EmptyRegistry{},
                    .ledstrip = struct {
                        pub const Periph = struct {
                            label: @Type(.enum_literal),
                            id: u32,
                            pixel_count: usize,
                            control_type: type,
                        };

                        periphs: [1]Periph = .{
                            .{ .label = .strip, .id = 2, .pixel_count = 1, .control_type = embed.ledstrip.LedStrip },
                        },
                        len: usize = 1,
                    }{},
                    .modem = EmptyRegistry{},
                    .nfc = EmptyRegistry{},
                    .wifi_sta = EmptyRegistry{},
                    .wifi_ap = EmptyRegistry{},
                    .flow = EmptyRegistry{},
                    .overlay = EmptyRegistry{},
                    .router = EmptyRegistry{},
                    .selection = EmptyRegistry{},
                };

                strip: embed.ledstrip.LedStrip,

                pub fn init(config: InitConfig) !@This() {
                    _ = config.allocator;
                    _ = config.button;
                    return .{
                        .strip = config.strip,
                    };
                }

                pub fn deinit(_: *@This()) void {}

                pub fn start(_: *@This(), _: StartConfig) !void {}

                pub fn stop(_: *@This()) !void {}

                pub fn press_single_button(_: *@This(), label: PeriphLabel) !void {
                    if (label != .button) return error.InvalidPeriphKind;
                }

                pub fn release_single_button(self: *@This(), label: PeriphLabel) !void {
                    if (label != .button) return error.InvalidPeriphKind;
                    self.strip.setPixel(0, embed.ledstrip.Color.green);
                    self.strip.refresh();
                }
            };

            const GenericApp = make(FakeZuxApp);
            var app = GenericApp.init(std.testing.allocator, .{
                .address = desktop_http.AddrPort.from4(.{ 127, 0, 0, 1 }, 0),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            app.deinit();
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
