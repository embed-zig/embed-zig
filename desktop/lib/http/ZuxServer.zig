const std = @import("std");
const embed = @import("embed");
const gstd = @import("gstd");
const codegen = @import("codegen");

const api = @import("api.zig");
const device = @import("../device.zig");
const ui_assets = @import("desktop_ui_assets");

const Sse = codegen.sse.make(gstd.runtime.std);

pub fn make(comptime ZuxApp: type) type {
    comptime validateZuxApp(ZuxApp);

    const registries = ZuxApp.registries;
    const gpio_count = registries.gpio_button.len;
    const ledstrip_count = registries.ledstrip.len;
    const total_gears = gpio_count + ledstrip_count;

    return struct {
        const Server = @This();

        pub const AddrPort = gstd.runtime.net.netip.AddrPort;
        pub const Listener = gstd.runtime.net.Listener;

        allocator: gstd.runtime.std.mem.Allocator,
        inner: gstd.runtime.net.http.Server,
        api_handler: *ApiHandler,
        ui: *UiHandler,

        pub const Options = struct {
            server: gstd.runtime.net.http.Server.Options = .{},
            assets_dir: ?[]const u8 = null,
        };

        pub fn init(allocator: gstd.runtime.std.mem.Allocator, options: Options) !Server {
            var inner = try gstd.runtime.net.http.Server.init(allocator, options.server);
            errdefer inner.deinit();

            const api_handler = try allocator.create(ApiHandler);
            errdefer allocator.destroy(api_handler);
            api_handler.* = try ApiHandler.init(allocator);
            errdefer api_handler.deinit(allocator);

            const ui = try allocator.create(UiHandler);
            errdefer allocator.destroy(ui);
            ui.* = try UiHandler.init(allocator, options.assets_dir);
            errdefer ui.deinit(allocator);

            try inner.handle("/topology", api_handler.handler());
            try inner.handle("/state", api_handler.handler());
            try inner.handle("/events", api_handler.handler());
            try inner.handle("/emit/", api_handler.handler());
            try inner.handle("/", gstd.runtime.net.http.Handler.init(ui));

            return .{
                .allocator = allocator,
                .inner = inner,
                .api_handler = api_handler,
                .ui = ui,
            };
        }

        pub fn deinit(self: *Server) void {
            self.inner.deinit();
            self.api_handler.deinit(self.allocator);
            self.allocator.destroy(self.api_handler);
            self.ui.deinit(self.allocator);
            self.allocator.destroy(self.ui);
            self.* = undefined;
        }

        pub fn serve(self: *Server, listener: Listener) !void {
            return self.inner.serve(listener);
        }

        pub fn listenAndServe(self: *Server, address: AddrPort) !void {
            var listener = try gstd.runtime.net.listen(self.allocator, .{ .address = address });
            defer listener.deinit();
            try self.inner.serve(listener);
        }

        pub fn close(self: *Server) void {
            self.inner.close();
        }

        const ApiHandler = struct {
            allocator: gstd.runtime.std.mem.Allocator,
            runtime: *RuntimeState,
            server: api.ServerApi,

            fn init(allocator: gstd.runtime.std.mem.Allocator) !@This() {
                const runtime = try allocator.create(RuntimeState);
                errdefer allocator.destroy(runtime);
                runtime.* = try RuntimeState.init(allocator);
                errdefer runtime.deinit();

                const server = try api.ServerApi.init(allocator, runtime, .{
                    .getTopology = RuntimeState.handleGetTopology,
                    .getState = RuntimeState.handleGetState,
                    .emitInputEvent = RuntimeState.handleEmitInputEvent,
                    .openEventStream = RuntimeState.handleOpenEventStream,
                });
                errdefer {
                    var doomed = server;
                    doomed.deinit();
                }

                return .{
                    .allocator = allocator,
                    .runtime = runtime,
                    .server = server,
                };
            }

            fn deinit(self: *@This(), allocator: gstd.runtime.std.mem.Allocator) void {
                self.server.deinit();
                self.runtime.deinit();
                allocator.destroy(self.runtime);
                self.* = undefined;
            }

            fn handler(self: *@This()) gstd.runtime.net.http.Handler {
                return self.server.handler();
            }
        };

        const RuntimeState = struct {
            allocator: gstd.runtime.std.mem.Allocator,
            app: ZuxApp,
            mutex: gstd.runtime.std.Thread.Mutex = .{},
            buttons: [gpio_count]device.single_button.SingleButton,
            strips: [ledstrip_count]device.ledstrip.LedStrip,
            revision: gstd.runtime.std.atomic.Value(u64) = gstd.runtime.std.atomic.Value(u64).init(1),

            const Self = @This();
            const Models = api.Models;

            const EmitError = error{
                InvalidEvent,
                UnknownGear,
            };

            const EventStream = struct {
                allocator: gstd.runtime.std.mem.Allocator,
                runtime: *RuntimeState,
                last_revision: u64 = 0,

                fn send(ptr: *anyopaque, writer: *Sse.Writer) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    defer self.allocator.destroy(self);
                    try self.run(writer);
                }

                fn run(self: *@This(), writer: *Sse.Writer) !void {
                    if (!(try self.runtime.writeSnapshotEvent(self.allocator, writer, nowMs()))) return;
                    self.last_revision = self.runtime.currentRevision();

                    while (true) {
                        gstd.runtime.std.Thread.sleep(20 * std.time.ns_per_ms);

                        const revision = self.runtime.currentRevision();
                        if (revision != self.last_revision) {
                            if (!(try self.runtime.writeSnapshotEvent(self.allocator, writer, nowMs()))) return;
                            self.last_revision = revision;
                        }
                    }
                }
            };

            fn init(allocator: gstd.runtime.std.mem.Allocator) !Self {
                var buttons = [_]device.single_button.SingleButton{.{}} ** gpio_count;
                var strips = try initStripDevices(allocator);
                errdefer deinitStripDevices(&strips);

                var app = try ZuxApp.init(makeInitConfig(allocator, &buttons, &strips));
                errdefer app.deinit();

                try app.start(.{ .ticker = .manual });
                errdefer app.stop() catch {};

                return .{
                    .allocator = allocator,
                    .app = app,
                    .buttons = buttons,
                    .strips = strips,
                };
            }

            fn deinit(self: *Self) void {
                self.app.stop() catch {};
                self.app.deinit();
                deinitStripDevices(&self.strips);
                self.* = undefined;
            }

            fn makeTopologyResponse(_: *Self, allocator: gstd.runtime.std.mem.Allocator) !Models.TopologyResponse {
                const gears = try allocator.alloc(Models.GearTopology, total_gears);
                var index: usize = 0;

                inline for (0..gpio_count) |i| {
                    const periph = registries.gpio_button.periphs[i];
                    gears[index] = .{
                        .kind = "single_button",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                    };
                    index += 1;
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    gears[index] = .{
                        .kind = "ledstrip",
                        .label = comptime labelText(periph.label),
                        .pixel_count = @intCast(periph.pixel_count),
                    };
                    index += 1;
                }

                return .{ .gears = gears };
            }

            fn makeStateResponse(self: *Self, allocator: gstd.runtime.std.mem.Allocator, ts_ms: i64) !Models.StateResponse {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.makeStateResponseLocked(allocator, ts_ms);
            }

            fn makeStateResponseLocked(self: *Self, allocator: gstd.runtime.std.mem.Allocator, ts_ms: i64) !Models.StateResponse {
                const gears = try allocator.alloc(Models.GearState, total_gears);
                var index: usize = 0;
                errdefer {
                    for (gears[0..index]) |*gear| {
                        switch (gear.*) {
                            .LedStripState => |*strip_state| allocator.free(strip_state.pixels),
                            else => {},
                        }
                    }
                    allocator.free(gears);
                }

                inline for (0..gpio_count) |i| {
                    const periph = registries.gpio_button.periphs[i];
                    gears[index] = @unionInit(Models.GearState, "SingleButtonState", .{
                        .kind = "single_button",
                        .label = comptime labelText(periph.label),
                        .pressed = try self.buttons[i].isPressed(),
                    });
                    index += 1;
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    const snapshot = self.strips[i].snapshot();
                    gears[index] = @unionInit(Models.GearState, "LedStripState", .{
                        .kind = "ledstrip",
                        .label = comptime labelText(periph.label),
                        .pixels = try copyPixels(allocator, snapshot.pixels),
                        .refresh_count = @intCast(snapshot.refresh_count),
                    });
                    index += 1;
                }

                return .{
                    .gears = gears,
                    .ts_ms = ts_ms,
                };
            }

            fn deinitStateResponse(allocator: gstd.runtime.std.mem.Allocator, response: *Models.StateResponse) void {
                for (response.gears) |*gear| {
                    switch (gear.*) {
                        .LedStripState => |*strip_state| allocator.free(strip_state.pixels),
                        else => {},
                    }
                }
                allocator.free(response.gears);
                response.* = undefined;
            }

            fn emit(self: *Self, gear_label: []const u8, event_name: []const u8, ts_ms: i64, metadata: ?[]const u8) EmitError!Models.EmitAck {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.emitLocked(gear_label, event_name, ts_ms, metadata);
            }

            fn emitLocked(self: *Self, gear_label: []const u8, event_name: []const u8, ts_ms: i64, metadata: ?[]const u8) EmitError!Models.EmitAck {
                inline for (0..gpio_count) |i| {
                    const periph = registries.gpio_button.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    if (gstd.runtime.std.mem.eql(u8, gear_label, label_name)) {
                        if (gstd.runtime.std.mem.eql(u8, event_name, "press")) {
                            self.buttons[i].press();
                            self.app.press_single_button(periph.label) catch return error.InvalidEvent;
                        } else if (gstd.runtime.std.mem.eql(u8, event_name, "release")) {
                            self.buttons[i].release();
                            self.app.release_single_button(periph.label) catch return error.InvalidEvent;
                        } else {
                            return error.InvalidEvent;
                        }

                        self.bumpRevision();
                        return .{
                            .accepted = true,
                            .event = event_name,
                            .gear_label = gear_label,
                            .metadata = metadata,
                            .ts = ts_ms,
                        };
                    }
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    if (gstd.runtime.std.mem.eql(u8, gear_label, comptime labelText(periph.label))) {
                        return error.InvalidEvent;
                    }
                }

                return error.UnknownGear;
            }

            fn currentRevision(self: *Self) u64 {
                return self.revision.load(.acquire);
            }

            fn bumpRevision(self: *Self) void {
                _ = self.revision.fetchAdd(1, .acq_rel);
            }

            fn writeSnapshotEvent(self: *Self, allocator: gstd.runtime.std.mem.Allocator, writer: *Sse.Writer, ts_ms: i64) !bool {
                var payload = try self.makeStateResponse(allocator, ts_ms);
                defer deinitStateResponse(allocator, &payload);
                return writeJsonEvent(allocator, writer, "state.snapshot", payload);
            }

            fn handleGetTopology(
                ptr: *anyopaque,
                _: glibContext(),
                allocator: gstd.runtime.std.mem.Allocator,
                _: api.ServerApi.operations.getTopology.Args,
            ) anyerror!api.ServerApi.operations.getTopology.Response {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return .{ .status_200 = try self.makeTopologyResponse(allocator) };
            }

            fn handleGetState(
                ptr: *anyopaque,
                _: glibContext(),
                allocator: gstd.runtime.std.mem.Allocator,
                _: api.ServerApi.operations.getState.Args,
            ) anyerror!api.ServerApi.operations.getState.Response {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return .{ .status_200 = try self.makeStateResponse(allocator, nowMs()) };
            }

            fn handleEmitInputEvent(
                ptr: *anyopaque,
                _: glibContext(),
                _: gstd.runtime.std.mem.Allocator,
                args: api.ServerApi.operations.emitInputEvent.Args,
            ) anyerror!api.ServerApi.operations.emitInputEvent.Response {
                const self: *Self = @ptrCast(@alignCast(ptr));
                const metadata = if (@hasField(@TypeOf(args.query), "metadata")) args.query.metadata else null;
                const result = self.emit(args.path.gear_label, args.path.event, args.query.ts, metadata) catch |err| {
                    return switch (err) {
                        error.InvalidEvent => .{ .status_400 = makeErrorResponse("INVALID_EVENT", "Unsupported event.") },
                        error.UnknownGear => .{ .status_404 = makeErrorResponse("UNKNOWN_GEAR", "Unknown gear label.") },
                    };
                };
                return .{ .status_200 = result };
            }

            fn handleOpenEventStream(
                ptr: *anyopaque,
                _: glibContext(),
                _: gstd.runtime.std.mem.Allocator,
                _: api.ServerApi.operations.openEventStream.Args,
            ) anyerror!api.ServerApi.operations.openEventStream.Response {
                const self: *Self = @ptrCast(@alignCast(ptr));
                const stream = try self.allocator.create(EventStream);
                stream.* = .{
                    .allocator = self.allocator,
                    .runtime = self,
                    .last_revision = self.currentRevision(),
                };
                return .{
                    .status_200 = .{
                        .ptr = stream,
                        .send = EventStream.send,
                    },
                };
            }

            fn initStripDevices(allocator: gstd.runtime.std.mem.Allocator) ![ledstrip_count]device.ledstrip.LedStrip {
                var strips: [ledstrip_count]device.ledstrip.LedStrip = undefined;
                var initialized: usize = 0;
                errdefer {
                    for (0..initialized) |i| strips[i].deinit();
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    strips[i] = try device.ledstrip.LedStrip.init(allocator, periph.pixel_count);
                    initialized += 1;
                }
                return strips;
            }

            fn deinitStripDevices(strips: *[ledstrip_count]device.ledstrip.LedStrip) void {
                inline for (0..ledstrip_count) |i| {
                    strips[i].deinit();
                }
            }

            fn makeInitConfig(
                allocator: gstd.runtime.std.mem.Allocator,
                buttons: *[gpio_count]device.single_button.SingleButton,
                strips: *[ledstrip_count]device.ledstrip.LedStrip,
            ) ZuxApp.InitConfig {
                var init_config: ZuxApp.InitConfig = undefined;
                if (@hasField(ZuxApp.InitConfig, "custom_pipeline_node")) {
                    init_config.custom_pipeline_node = null;
                }
                inline for (@typeInfo(ZuxApp.InitConfig).@"struct".fields) |field| {
                    if (isOptionalOf(field.type, ZuxApp.ReducerHook)) {
                        @compileError("desktop ZuxServer cannot synthesize runtime reducer hook field '" ++ field.name ++ "'");
                    }
                    if (isOptionalOf(field.type, ZuxApp.RenderHook)) {
                        @compileError("desktop ZuxServer cannot synthesize runtime render hook field '" ++ field.name ++ "'");
                    }
                }
                init_config.allocator = allocator;

                inline for (0..gpio_count) |i| {
                    const periph = registries.gpio_button.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = embed.drivers.button.Single.init(device.single_button.SingleButton, &buttons[i]);
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = strips[i].handle();
                }

                return init_config;
            }

            fn isOptionalOf(comptime FieldType: type, comptime ChildType: type) bool {
                if (ChildType == void) return false;
                const info = @typeInfo(FieldType);
                return info == .optional and info.optional.child == ChildType;
            }
        };

        const UiHandler = struct {
            assets: ResolvedAssets,

            fn init(allocator: gstd.runtime.std.mem.Allocator, assets_dir: ?[]const u8) !@This() {
                return .{
                    .assets = try resolveAssets(allocator, assets_dir),
                };
            }

            fn deinit(self: *@This(), allocator: gstd.runtime.std.mem.Allocator) void {
                self.assets.deinit(allocator);
                self.* = undefined;
            }

            pub fn serveHTTP(
                self: *@This(),
                rw: *gstd.runtime.net.http.ResponseWriter,
                req: *gstd.runtime.net.http.Request,
            ) void {
                serveUi(&self.assets, rw, req);
            }
        };

        const Asset = struct {
            file_name: []const u8,
            content_type: []const u8,
            body: []const u8,
        };

        const ResolvedAssets = struct {
            index_html: []const u8 = ui_assets.index_html,
            main_js: []const u8 = ui_assets.main_js,
            desktop_core_js: []const u8 = ui_assets.desktop_core_js,
            styles_css: []const u8 = ui_assets.styles_css,
            owns_main_js: bool = false,

            fn deinit(self: *@This(), allocator: gstd.runtime.std.mem.Allocator) void {
                if (self.owns_main_js) allocator.free(self.main_js);
                self.* = undefined;
            }
        };

        pub fn serveUi(
            assets: *const ResolvedAssets,
            rw: *gstd.runtime.net.http.ResponseWriter,
            req: *gstd.runtime.net.http.Request,
        ) void {
            const path = if (req.url.path.len == 0) "/" else req.url.path;

            if (lookupAsset(assets, path)) |asset| {
                return serveAsset(rw, gstd.runtime.net.http.status.ok, asset.content_type, asset.body);
            }

            return serveAsset(rw, gstd.runtime.net.http.status.not_found, "text/plain; charset=utf-8", "not found\n");
        }

        fn resolveAssets(allocator: gstd.runtime.std.mem.Allocator, assets_dir: ?[]const u8) !ResolvedAssets {
            var assets = ResolvedAssets{};

            if (assets_dir) |dir| {
                if (tryReadExternalMainJs(allocator, dir)) |main_js| {
                    assets.main_js = main_js;
                    assets.owns_main_js = true;
                }
            }

            return assets;
        }

        fn lookupAsset(assets: *const ResolvedAssets, path: []const u8) ?Asset {
            if (gstd.runtime.std.mem.eql(u8, path, "/") or gstd.runtime.std.mem.eql(u8, path, "/index.html")) {
                return .{
                    .file_name = "index.html",
                    .content_type = "text/html; charset=utf-8",
                    .body = assets.index_html,
                };
            }
            if (gstd.runtime.std.mem.eql(u8, path, "/main.js") or gstd.runtime.std.mem.eql(u8, path, "/index.js")) {
                return .{
                    .file_name = "main.js",
                    .content_type = "application/javascript; charset=utf-8",
                    .body = assets.main_js,
                };
            }
            if (gstd.runtime.std.mem.eql(u8, path, "/desktop-core.js")) {
                return .{
                    .file_name = "desktop-core.js",
                    .content_type = "application/javascript; charset=utf-8",
                    .body = assets.desktop_core_js,
                };
            }
            if (gstd.runtime.std.mem.eql(u8, path, "/styles.css") or gstd.runtime.std.mem.eql(u8, path, "/index.css")) {
                return .{
                    .file_name = "styles.css",
                    .content_type = "text/css; charset=utf-8",
                    .body = assets.styles_css,
                };
            }
            return null;
        }

        fn tryReadExternalMainJs(
            allocator: gstd.runtime.std.mem.Allocator,
            assets_dir: []const u8,
        ) ?[]u8 {
            const full_path = std.fs.path.join(std.heap.page_allocator, &.{ assets_dir, "main.js" }) catch return null;
            defer std.heap.page_allocator.free(full_path);

            const file = openAssetFile(full_path) catch return null;
            defer file.close();

            return file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch return null;
        }

        fn openAssetFile(full_path: []const u8) !std.fs.File {
            if (std.fs.path.isAbsolute(full_path)) {
                return std.fs.openFileAbsolute(full_path, .{});
            }
            return std.fs.cwd().openFile(full_path, .{});
        }

        fn serveAsset(
            rw: *gstd.runtime.net.http.ResponseWriter,
            status_code: u16,
            content_type: []const u8,
            body: []const u8,
        ) void {
            writeResponse(rw, status_code, content_type, body);
        }

        fn writeResponse(
            rw: *gstd.runtime.net.http.ResponseWriter,
            status_code: u16,
            content_type: []const u8,
            body: []const u8,
        ) void {
            var content_length_buf: [32]u8 = undefined;
            const content_length = gstd.runtime.std.fmt.bufPrint(&content_length_buf, "{d}", .{body.len}) catch return;

            rw.setHeader(gstd.runtime.net.http.Header.cache_control, "no-store") catch return;
            rw.setHeader(gstd.runtime.net.http.Header.content_type, content_type) catch return;
            rw.setHeader(gstd.runtime.net.http.Header.content_length, content_length) catch return;
            rw.writeHeader(status_code) catch return;
            _ = rw.write(body) catch {};
        }
    };
}

fn validateZuxApp(comptime ZuxApp: type) void {
    if (!@hasDecl(ZuxApp, "registries")) @compileError("desktop ZuxServer requires ZuxApp.registries");
    if (!@hasDecl(ZuxApp, "InitConfig")) @compileError("desktop ZuxServer requires ZuxApp.InitConfig");
    if (!@hasDecl(ZuxApp, "StartConfig")) @compileError("desktop ZuxServer requires ZuxApp.StartConfig");
    if (!@hasDecl(ZuxApp, "PeriphLabel")) @compileError("desktop ZuxServer requires ZuxApp.PeriphLabel");
    _ = @as(*const fn (ZuxApp.InitConfig) anyerror!ZuxApp, &ZuxApp.init);
    _ = @as(*const fn (*ZuxApp) void, &ZuxApp.deinit);
    _ = @as(*const fn (*ZuxApp, ZuxApp.StartConfig) anyerror!void, &ZuxApp.start);
    _ = @as(*const fn (*ZuxApp) anyerror!void, &ZuxApp.stop);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel) anyerror!void, &ZuxApp.press_single_button);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel) anyerror!void, &ZuxApp.release_single_button);

    const registries = ZuxApp.registries;
    if (registries.adc_button.len != 0) @compileError("desktop ZuxServer does not support grouped buttons yet");
    if (registries.imu.len != 0) @compileError("desktop ZuxServer does not support imu yet");
    if (registries.modem.len != 0) @compileError("desktop ZuxServer does not support modem yet");
    if (registries.nfc.len != 0) @compileError("desktop ZuxServer does not support nfc yet");
    if (registries.wifi_sta.len != 0) @compileError("desktop ZuxServer does not support wifi sta yet");
    if (registries.wifi_ap.len != 0) @compileError("desktop ZuxServer does not support wifi ap yet");
}

fn labelText(comptime label: anytype) []const u8 {
    return @tagName(label);
}

fn glibContext() type {
    return @import("glib").context.Context;
}

fn writeJsonEvent(allocator: gstd.runtime.std.mem.Allocator, writer: *Sse.Writer, event_name: []const u8, payload: anytype) !bool {
    const encoded = try gstd.runtime.std.fmt.allocPrint(allocator, "{f}", .{gstd.runtime.std.json.fmt(payload, .{})});
    defer allocator.free(encoded);

    writer.event(.{
        .data = encoded,
        .event = event_name,
    }) catch return false;
    writer.flush() catch return false;
    return true;
}

fn copyPixels(allocator: gstd.runtime.std.mem.Allocator, source: []const embed.ledstrip.Color) ![]api.Models.Color {
    const pixels = try allocator.alloc(api.Models.Color, source.len);
    for (source, 0..) |pixel, index| {
        pixels[index] = .{
            .r = pixel.r,
            .g = pixel.g,
            .b = pixel.b,
        };
    }
    return pixels;
}

fn makeErrorResponse(code: []const u8, message: []const u8) api.Models.ErrorResponse {
    return @as(api.Models.ErrorResponse, .{
        .error_ = .{
            .code = code,
            .message = message,
        },
    });
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}
