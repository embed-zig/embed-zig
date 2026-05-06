const glib = @import("glib");

pub fn make(comptime Host: type) type {
    comptime validateZuxHost(Host);
    const zux_app = Host.ZuxApp;
    const init_config = zux_app.InitConfig;
    const start_config = zux_app.StartConfig;
    const allocator_type = allocatorType(init_config);

    return struct {
        const Self = @This();

        pub const AppHost = Host;
        pub const ZuxApp = zux_app;
        pub const InitConfig = init_config;
        pub const StartConfig = start_config;
        pub const Allocator = allocator_type;

        app_host: *AppHost,

        pub fn init(app_allocator: Allocator, app_init_config: InitConfig) !Self {
            return .{
                .app_host = try AppHost.init(app_allocator, app_init_config),
            };
        }

        pub fn deinit(self: *Self) void {
            self.app_host.deinit();
            self.* = undefined;
        }

        pub fn app(self: *Self) *AppHost {
            return self.app_host;
        }

        pub fn zux(self: *Self) *ZuxApp {
            const app_host = self.app();
            if (comptime @hasDecl(AppHost, "zux")) {
                return app_host.zux();
            }
            return &app_host.zux_app;
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            if (!@hasDecl(AppHost, "createTestRunner")) {
                @compileError("apps.Launcher requires AppHost.createTestRunner() for test runner construction");
            }
            return AppHost.createTestRunner();
        }
    };
}

fn validateZuxHost(comptime AppHost: type) void {
    requireStruct(AppHost, "apps.Launcher Zux app host");
    if (!@hasDecl(AppHost, "ZuxApp")) {
        @compileError("apps.Launcher Zux app host requires pub const ZuxApp");
    }

    const ZuxApp = AppHost.ZuxApp;
    validateZuxApp(ZuxApp);

    const Allocator = allocatorType(ZuxApp.InitConfig);
    _ = @as(*const fn (Allocator, ZuxApp.InitConfig) anyerror!*AppHost, &AppHost.init);
    _ = @as(*const fn (*AppHost) void, &AppHost.deinit);

    if (@hasDecl(AppHost, "zux")) {
        _ = @as(*const fn (*AppHost) *ZuxApp, &AppHost.zux);
    } else {
        if (!@hasField(AppHost, "zux_app")) {
            @compileError("apps.Launcher Zux app host requires zux(self) or zux_app field");
        }
        if (@FieldType(AppHost, "zux_app") != ZuxApp) {
            @compileError("apps.Launcher Zux app host zux_app field must be ZuxApp");
        }
    }
}

fn validateZuxApp(comptime ZuxApp: type) void {
    requireStruct(ZuxApp, "apps.Launcher ZuxApp");
    if (!@hasDecl(ZuxApp, "InitConfig")) {
        @compileError("apps.Launcher ZuxApp requires InitConfig");
    }
    if (!@hasDecl(ZuxApp, "StartConfig")) {
        @compileError("apps.Launcher ZuxApp requires StartConfig");
    }
    _ = allocatorType(ZuxApp.InitConfig);
    _ = @as(*const fn (*ZuxApp) void, &ZuxApp.deinit);
    _ = @as(*const fn (*ZuxApp, ZuxApp.StartConfig) anyerror!void, &ZuxApp.start);
    _ = @as(*const fn (*ZuxApp) anyerror!void, &ZuxApp.stop);
}

fn allocatorType(comptime InitConfig: type) type {
    requireStruct(InitConfig, "apps.Launcher ZuxApp.InitConfig");
    if (!@hasField(InitConfig, "allocator")) {
        @compileError("apps.Launcher ZuxApp.InitConfig requires allocator field");
    }
    return @FieldType(InitConfig, "allocator");
}

fn requireStruct(comptime T: type, comptime label: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError(label ++ " must be a struct"),
    }
}
