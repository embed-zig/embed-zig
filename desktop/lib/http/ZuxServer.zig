const std = @import("std");
const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const codegen = @import("codegen");

const api = @import("api.zig");
const device = @import("../device.zig");
const desktop_log = @import("../log.zig");
const ui_assets = @import("desktop_ui_assets");

const Sse = codegen.sse.make(gstd.runtime);
const display_event_ring_size = 128;
const log_stream_heartbeat_ticks = 25;
const event_stream_heartbeat_ticks = 250;

const TouchPointQuery = struct {
    x: u16,
    y: u16,
};

const DisplayEvent = struct {
    seq: u64 = 0,
    label: []const u8 = &.{},
    ts_ms: i64 = 0,
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    pixel_format: []const u8 = "rgb888",
    pixels: []u8 = &.{},
    refresh_count: u64 = 0,
};

pub fn make(comptime Launcher: type) type {
    comptime validateLauncher(Launcher);

    const AppHost = Launcher.AppHost;
    const ZuxApp = Launcher.ZuxApp;
    const registries = ZuxApp.registries;
    const audio_system_count = registries.audio_system.len;
    const display_count = registries.display.len;
    const single_button_count = registries.single_button.len;
    const exposed_single_button_count = exposedButtonCount(registries.single_button);
    const grouped_button_count = registries.adc_button.len;
    const exposed_grouped_button_count = exposedButtonCount(registries.adc_button);
    const ledstrip_count = registries.ledstrip.len;
    const modem_count = registries.modem.len;
    const nfc_count = registries.nfc.len;
    const touch_count = registries.touch.len;
    const wifi_sta_count = registries.wifi_sta.len;
    const has_bt_host = @hasField(ZuxApp.InitConfig, "bt");
    const topology_gear_count = exposed_single_button_count + exposed_grouped_button_count + ledstrip_count + display_count + modem_count + nfc_count + touch_count + wifi_sta_count;
    const state_gear_count = exposed_single_button_count + exposed_grouped_button_count + ledstrip_count + display_count + wifi_sta_count;

    return struct {
        const Server = @This();

        pub const AddrPort = gstd.runtime.net.netip.AddrPort;
        pub const Listener = gstd.runtime.net.Listener;

        allocator: gstd.runtime.std.mem.Allocator,
        inner: gstd.runtime.net.http.Server,
        api_handler: *ApiHandler,
        log_handler: *LogHandler,
        ui: *UiHandler,

        pub const Options = struct {
            server: gstd.runtime.net.http.Server.Options = .{},
            assets_dir: ?[]const u8 = null,
            start_config: ZuxApp.StartConfig = .{},
        };

        pub fn init(allocator: gstd.runtime.std.mem.Allocator, options: Options) !Server {
            var inner = try gstd.runtime.net.http.Server.init(allocator, options.server);
            errdefer inner.deinit();

            const api_handler = try allocator.create(ApiHandler);
            errdefer allocator.destroy(api_handler);
            api_handler.* = try ApiHandler.init(allocator, options.start_config);
            errdefer api_handler.deinit(allocator);

            const ui = try allocator.create(UiHandler);
            errdefer allocator.destroy(ui);
            ui.* = try UiHandler.init(allocator, options.assets_dir);
            errdefer ui.deinit(allocator);

            const log_handler = try allocator.create(LogHandler);
            errdefer allocator.destroy(log_handler);
            log_handler.* = .{};

            try inner.handle("/topology", api_handler.handler());
            try inner.handle("/state", api_handler.handler());
            try inner.handle("/events", api_handler.handler());
            try inner.handle("/logs", gstd.runtime.net.http.Handler.init(log_handler));
            try inner.handle("/emit/", api_handler.handler());
            try inner.handle("/", gstd.runtime.net.http.Handler.init(ui));

            return .{
                .allocator = allocator,
                .inner = inner,
                .api_handler = api_handler,
                .log_handler = log_handler,
                .ui = ui,
            };
        }

        pub fn deinit(self: *Server) void {
            self.inner.deinit();
            self.api_handler.deinit(self.allocator);
            self.allocator.destroy(self.api_handler);
            self.allocator.destroy(self.log_handler);
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

            fn init(allocator: gstd.runtime.std.mem.Allocator, start_config: ZuxApp.StartConfig) !@This() {
                const runtime = try allocator.create(RuntimeState);
                errdefer allocator.destroy(runtime);
                try runtime.init(allocator, start_config);
                errdefer runtime.deinit();
                runtime.attachStripRefreshHooks();
                runtime.attachDisplayRefreshHooks();

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

        const LogHandler = struct {
            pub fn serveHTTP(
                self: *@This(),
                rw: *gstd.runtime.net.http.ResponseWriter,
                req: *gstd.runtime.net.http.Request,
            ) void {
                _ = self;
                _ = req;

                var writer = Sse.Writer.init(rw);
                writer.begin(gstd.runtime.net.http.status.ok) catch return;
                writer.flush() catch return;

                var last_seq: u64 = 0;
                var heartbeat_ticks: usize = 0;
                while (true) {
                    var copied: [32]desktop_log.CopiedEntry = [_]desktop_log.CopiedEntry{.{}} ** 32;
                    const count = desktop_log.copySince(last_seq, copied[0..]);
                    var wrote = false;
                    for (copied[0..count]) |*entry| {
                        var id_buf: [32]u8 = undefined;
                        const id = gstd.runtime.std.fmt.bufPrint(&id_buf, "{d}", .{entry.seq}) catch return;
                        writer.event(.{
                            .event = "log",
                            .id = id,
                            .data = entry.bytes(),
                        }) catch return;
                        writer.flush() catch return;
                        last_seq = entry.seq;
                        wrote = true;
                    }

                    if (wrote) {
                        heartbeat_ticks = 0;
                    } else {
                        heartbeat_ticks += 1;
                        if (heartbeat_ticks >= log_stream_heartbeat_ticks) {
                            if (!writeSseHeartbeat(&writer)) return;
                            heartbeat_ticks = 0;
                        }
                    }

                    gstd.runtime.time.sleep(200 * std.time.ns_per_ms);
                }
            }
        };

        const RuntimeState = struct {
            allocator: gstd.runtime.std.mem.Allocator,
            launcher: Launcher,
            mutex: gstd.runtime.sync.Mutex = .{},
            audio_systems: [audio_system_count]device.audio_system.AudioSystem,
            buttons: [single_button_count]device.single_button.SingleButton,
            grouped_buttons: [grouped_button_count]device.grouped_button.GroupedButton,
            displays: [display_count]device.display.Display,
            modems: [modem_count]device.modem.Modem,
            nfcs: [nfc_count]device.nfc.Nfc,
            strips: [ledstrip_count]device.ledstrip.LedStrip,
            touches: [touch_count]device.touch.Touch,
            wifi_stas: [wifi_sta_count]device.wifi_sta.WifiSta,
            bt_host: if (has_bt_host) device.bt_host.BtHost else void,
            revision: gstd.runtime.std.atomic.Value(u64) = gstd.runtime.std.atomic.Value(u64).init(1),
            display_events: [display_event_ring_size]DisplayEvent = [_]DisplayEvent{.{}} ** display_event_ring_size,
            next_display_event_seq: u64 = 1,

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
                last_display_event_seq: u64 = 0,

                fn send(ptr: *anyopaque, writer: *Sse.Writer) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    defer self.allocator.destroy(self);
                    try self.run(writer);
                }

                fn run(self: *@This(), writer: *Sse.Writer) !void {
                    if (!(try self.runtime.writeSnapshotEvent(self.allocator, writer, nowMs()))) return;
                    self.last_revision = self.runtime.currentRevision();
                    var heartbeat_ticks: usize = 0;

                    while (true) {
                        gstd.runtime.time.sleep(20 * std.time.ns_per_ms);

                        const previous_display_event_seq = self.last_display_event_seq;
                        self.last_display_event_seq = try self.runtime.writeDisplayEventsSince(
                            self.allocator,
                            writer,
                            self.last_display_event_seq,
                        );
                        var wrote = self.last_display_event_seq != previous_display_event_seq;

                        const revision = self.runtime.currentRevision();
                        if (revision != self.last_revision) {
                            if (!(try self.runtime.writeSnapshotEvent(self.allocator, writer, nowMs()))) return;
                            self.last_revision = revision;
                            wrote = true;
                        }

                        if (wrote) {
                            heartbeat_ticks = 0;
                        } else {
                            heartbeat_ticks += 1;
                            if (heartbeat_ticks >= event_stream_heartbeat_ticks) {
                                if (!writeSseHeartbeat(writer)) return;
                                heartbeat_ticks = 0;
                            }
                        }
                    }
                }
            };

            fn init(self: *Self, allocator: gstd.runtime.std.mem.Allocator, start_config: ZuxApp.StartConfig) !void {
                self.allocator = allocator;
                self.mutex = .{};
                self.audio_systems = try initAudioSystemDevices(allocator);
                errdefer deinitAudioSystemDevices(&self.audio_systems);
                self.buttons = [_]device.single_button.SingleButton{.{}} ** single_button_count;
                self.grouped_buttons = [_]device.grouped_button.GroupedButton{.{}} ** grouped_button_count;
                self.displays = try initDisplayDevices(allocator);
                errdefer deinitDisplayDevices(&self.displays);
                self.modems = [_]device.modem.Modem{.{}} ** modem_count;
                self.nfcs = [_]device.nfc.Nfc{.{}} ** nfc_count;
                self.strips = try initStripDevices(allocator);
                errdefer deinitStripDevices(&self.strips);
                self.touches = [_]device.touch.Touch{.{}} ** touch_count;
                self.wifi_stas = try initWifiStaDevices(allocator);
                errdefer deinitWifiStaDevices(&self.wifi_stas);
                self.bt_host = if (has_bt_host) try device.bt_host.BtHost.init(allocator, .{ .allocator = allocator }) else {};
                errdefer if (has_bt_host) self.bt_host.deinit();
                self.revision = gstd.runtime.std.atomic.Value(u64).init(1);
                self.display_events = [_]DisplayEvent{.{}} ** display_event_ring_size;
                self.next_display_event_seq = 1;

                self.launcher = try Launcher.init(allocator, makeInitConfig(
                    allocator,
                    &self.audio_systems,
                    &self.buttons,
                    &self.grouped_buttons,
                    &self.displays,
                    &self.modems,
                    &self.nfcs,
                    &self.strips,
                    &self.touches,
                    &self.wifi_stas,
                    &self.bt_host,
                ));
                errdefer self.launcher.deinit();

                try self.launcher.zux().start(start_config);
                errdefer self.launcher.zux().stop() catch {};
            }

            fn deinit(self: *Self) void {
                self.launcher.zux().stop() catch {};
                self.launcher.deinit();
                self.deinitDisplayEvents();
                if (has_bt_host) self.bt_host.deinit();
                deinitWifiStaDevices(&self.wifi_stas);
                deinitAudioSystemDevices(&self.audio_systems);
                deinitDisplayDevices(&self.displays);
                deinitModemDevices(&self.modems);
                deinitStripDevices(&self.strips);
                self.* = undefined;
            }

            fn deinitDisplayEvents(self: *Self) void {
                for (&self.display_events) |*event| {
                    if (event.pixels.len != 0) {
                        self.allocator.free(event.pixels);
                    }
                    event.* = .{};
                }
            }

            fn attachStripRefreshHooks(self: *Self) void {
                inline for (0..ledstrip_count) |i| {
                    self.strips[i].setRefreshHook(self, onStripRefresh);
                }
            }

            fn onStripRefresh(ctx: *anyopaque, strip: *device.ledstrip.LedStrip) void {
                _ = strip;
                const self: *Self = @ptrCast(@alignCast(ctx));
                self.bumpRevision();
            }

            fn attachDisplayRefreshHooks(self: *Self) void {
                inline for (0..display_count) |i| {
                    self.displays[i].setRefreshHook(self, onDisplayRefresh);
                }
            }

            fn onDisplayRefresh(ctx: *anyopaque, display: *device.display.Display, update: device.display.Display.Update) void {
                const self: *Self = @ptrCast(@alignCast(ctx));
                inline for (0..display_count) |i| {
                    if (display == &self.displays[i]) {
                        self.pushDisplayEvent(comptime labelText(registries.display.periphs[i].label), update) catch {};
                        return;
                    }
                }
            }

            fn makeTopologyResponse(_: *Self, allocator: gstd.runtime.std.mem.Allocator) !Models.TopologyResponse {
                const gears = try allocator.alloc(Models.GearTopology, topology_gear_count);
                var index: usize = 0;

                inline for (0..single_button_count) |i| {
                    const periph = registries.single_button.periphs[i];
                    if (comptime isVirtualButton(periph)) continue;
                    gears[index] = .{
                        .kind = "single_button",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..grouped_button_count) |i| {
                    const periph = registries.adc_button.periphs[i];
                    if (comptime isVirtualButton(periph)) continue;
                    gears[index] = .{
                        .kind = "grouped_button",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = @intCast(periph.button_count),
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    gears[index] = .{
                        .kind = "ledstrip",
                        .label = comptime labelText(periph.label),
                        .pixel_count = @intCast(periph.pixel_count),
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..display_count) |i| {
                    const periph = registries.display.periphs[i];
                    gears[index] = .{
                        .kind = "display",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = periph.width,
                        .height = periph.height,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..modem_count) |i| {
                    const periph = registries.modem.periphs[i];
                    gears[index] = .{
                        .kind = "modem",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..nfc_count) |i| {
                    const periph = registries.nfc.periphs[i];
                    gears[index] = .{
                        .kind = "nfc",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..touch_count) |i| {
                    const periph = registries.touch.periphs[i];
                    gears[index] = .{
                        .kind = "touch",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = periph.target,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                inline for (0..wifi_sta_count) |i| {
                    const periph = registries.wifi_sta.periphs[i];
                    gears[index] = .{
                        .kind = "wifi_sta",
                        .label = comptime labelText(periph.label),
                        .pixel_count = null,
                        .button_count = null,
                        .width = null,
                        .height = null,
                        .target = null,
                        .metadata = topologyMetadata(periphMetadata(periph)),
                    };
                    index += 1;
                }

                return .{
                    .title = comptime appTitle(AppHost),
                    .description = comptime appDescription(AppHost),
                    .gears = gears,
                };
            }

            fn topologyMetadata(comptime metadata: embed.zux.Metadata) ?Models.GearMetadata {
                if (metadata.label_text == null and metadata.item_label_texts.len == 0) return null;
                return .{
                    .label_text = metadata.label_text,
                    .item_label_texts = if (metadata.item_label_texts.len == 0) null else metadata.item_label_texts,
                };
            }

            fn periphMetadata(comptime periph: anytype) embed.zux.Metadata {
                const PeriphType = @TypeOf(periph);
                if (@hasField(PeriphType, "metadata")) return periph.metadata;
                return .{};
            }

            fn makeStateResponse(self: *Self, allocator: gstd.runtime.std.mem.Allocator, ts_ms: i64) !Models.StateResponse {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.makeStateResponseLocked(allocator, ts_ms);
            }

            fn makeStateResponseLocked(self: *Self, allocator: gstd.runtime.std.mem.Allocator, ts_ms: i64) !Models.StateResponse {
                const gears = try allocator.alloc(Models.GearState, state_gear_count);
                var index: usize = 0;
                errdefer {
                    for (gears[0..index]) |*gear| {
                        switch (gear.*) {
                            .LedStripState => |*strip_state| allocator.free(strip_state.pixels),
                            .DisplayState => |*display_state| allocator.free(display_state.pixels),
                            .WifiStaState => |*wifi_state| if (wifi_state.current_ssid) |ssid| allocator.free(ssid),
                            else => {},
                        }
                    }
                    allocator.free(gears);
                }

                inline for (0..single_button_count) |i| {
                    const periph = registries.single_button.periphs[i];
                    if (comptime isVirtualButton(periph)) continue;
                    gears[index] = @unionInit(Models.GearState, "SingleButtonState", .{
                        .kind = "single_button",
                        .label = comptime labelText(periph.label),
                        .pressed = try self.buttons[i].isPressed(),
                    });
                    index += 1;
                }

                inline for (0..grouped_button_count) |i| {
                    const periph = registries.adc_button.periphs[i];
                    const pressed_button_id = if (try self.grouped_buttons[i].pressedButtonId()) |button_id|
                        @as(i64, @intCast(button_id))
                    else
                        null;
                    if (comptime isVirtualButton(periph)) continue;
                    gears[index] = @unionInit(Models.GearState, "GroupedButtonState", .{
                        .kind = "grouped_button",
                        .label = comptime labelText(periph.label),
                        .button_count = @intCast(periph.button_count),
                        .pressed_button_id = pressed_button_id,
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

                inline for (0..display_count) |i| {
                    const periph = registries.display.periphs[i];
                    const snapshot = try self.displays[i].snapshot(allocator);
                    defer allocator.free(snapshot.pixels);
                    gears[index] = @unionInit(Models.GearState, "DisplayState", .{
                        .kind = "display",
                        .label = comptime labelText(periph.label),
                        .width = snapshot.width,
                        .height = snapshot.height,
                        .pixel_format = "rgb888",
                        .pixels = try encodeDisplayPixelsBase64(allocator, snapshot.pixels),
                        .refresh_count = @intCast(snapshot.refresh_count),
                    });
                    index += 1;
                }

                inline for (0..wifi_sta_count) |i| {
                    const periph = registries.wifi_sta.periphs[i];
                    var ssid_buf: [embed.drivers.wifi.Sta.max_ssid_len]u8 = undefined;
                    const current_ssid = if (self.wifi_stas[i].getCurrentSsid(&ssid_buf)) |ssid|
                        try allocator.dupe(u8, ssid)
                    else
                        null;
                    gears[index] = @unionInit(Models.GearState, "WifiStaState", .{
                        .kind = "wifi_sta",
                        .label = comptime labelText(periph.label),
                        .state = wifiStaStateText(self.wifi_stas[i].getState()),
                        .has_ip = self.wifi_stas[i].getIpInfo() != null,
                        .current_ssid = current_ssid,
                        .last_error = self.wifi_stas[i].getLastConnectError(),
                    });
                    index += 1;
                }

                const app = try self.makeAppStateJson(allocator);
                errdefer if (app) |value| allocator.free(value);

                return .{
                    .gears = gears,
                    .ts_ms = ts_ms,
                    .app = app,
                };
            }

            fn makeAppStateJson(self: *Self, allocator: gstd.runtime.std.mem.Allocator) !?[]const u8 {
                if (comptime @hasDecl(AppHost, "desktopStateJson")) {
                    return try self.launcher.app().desktopStateJson(allocator);
                }
                return null;
            }

            fn deinitStateResponse(allocator: gstd.runtime.std.mem.Allocator, response: *Models.StateResponse) void {
                for (response.gears) |*gear| {
                    switch (gear.*) {
                        .LedStripState => |*strip_state| allocator.free(strip_state.pixels),
                        .DisplayState => |*display_state| allocator.free(display_state.pixels),
                        .WifiStaState => |*wifi_state| if (wifi_state.current_ssid) |ssid| allocator.free(ssid),
                        else => {},
                    }
                }
                allocator.free(response.gears);
                if (response.app) |app| allocator.free(app);
                response.* = undefined;
            }

            fn emit(self: *Self, gear_label: []const u8, event_name: []const u8, ts_ms: i64, metadata: ?[]const u8, touch_point: ?TouchPointQuery, button_id: ?u32) EmitError!Models.EmitAck {
                if (comptime @hasDecl(AppHost, "desktopEmit")) {
                    if (gstd.runtime.std.mem.eql(u8, gear_label, "app")) {
                        const accepted = self.launcher.app().desktopEmit(event_name, metadata) catch return error.InvalidEvent;
                        if (!accepted) return error.InvalidEvent;
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

                self.mutex.lock();
                defer self.mutex.unlock();
                return self.emitLocked(gear_label, event_name, ts_ms, metadata, touch_point, button_id);
            }

            fn emitLocked(self: *Self, gear_label: []const u8, event_name: []const u8, ts_ms: i64, metadata: ?[]const u8, touch_point: ?TouchPointQuery, button_id: ?u32) EmitError!Models.EmitAck {
                inline for (0..single_button_count) |i| {
                    const periph = registries.single_button.periphs[i];
                    if (comptime isVirtualButton(periph)) continue;
                    const label_name = comptime labelText(periph.label);
                    if (gstd.runtime.std.mem.eql(u8, gear_label, label_name)) {
                        if (gstd.runtime.std.mem.eql(u8, event_name, "press")) {
                            self.buttons[i].press();
                        } else if (gstd.runtime.std.mem.eql(u8, event_name, "release")) {
                            self.buttons[i].release();
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

                inline for (0..grouped_button_count) |i| {
                    const periph = registries.adc_button.periphs[i];
                    if (comptime isVirtualButton(periph)) continue;
                    const label_name = comptime labelText(periph.label);
                    if (gstd.runtime.std.mem.eql(u8, gear_label, label_name)) {
                        if (gstd.runtime.std.mem.eql(u8, event_name, "press")) {
                            const id = button_id orelse return error.InvalidEvent;
                            if (id >= periph.button_count) return error.InvalidEvent;
                            self.grouped_buttons[i].press(id);
                        } else if (gstd.runtime.std.mem.eql(u8, event_name, "release")) {
                            self.grouped_buttons[i].release();
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

                inline for (0..display_count) |i| {
                    const periph = registries.display.periphs[i];
                    if (gstd.runtime.std.mem.eql(u8, gear_label, comptime labelText(periph.label))) {
                        return error.InvalidEvent;
                    }
                }

                inline for (0..touch_count) |i| {
                    const periph = registries.touch.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    if (gstd.runtime.std.mem.eql(u8, gear_label, label_name)) {
                        if (gstd.runtime.std.mem.eql(u8, event_name, "down")) {
                            const point = touch_point orelse return error.InvalidEvent;
                            self.launcher.zux().touch_down(@field(ZuxApp.PeriphLabel, label_name), .{
                                .id = 0,
                                .x = point.x,
                                .y = point.y,
                                .pressure = 1,
                            }) catch return error.InvalidEvent;
                        } else if (gstd.runtime.std.mem.eql(u8, event_name, "move")) {
                            const point = touch_point orelse return error.InvalidEvent;
                            self.launcher.zux().touch_move(@field(ZuxApp.PeriphLabel, label_name), .{
                                .id = 0,
                                .x = point.x,
                                .y = point.y,
                                .pressure = 1,
                            }) catch return error.InvalidEvent;
                        } else if (gstd.runtime.std.mem.eql(u8, event_name, "up")) {
                            self.launcher.zux().touch_up(@field(ZuxApp.PeriphLabel, label_name)) catch return error.InvalidEvent;
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

                return error.UnknownGear;
            }

            fn currentRevision(self: *Self) u64 {
                return self.revision.load(.acquire);
            }

            fn bumpRevision(self: *Self) void {
                _ = self.revision.fetchAdd(1, .acq_rel);
            }

            fn currentDisplayEventSeq(self: *Self) u64 {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.next_display_event_seq -| 1;
            }

            fn pushDisplayEvent(self: *Self, comptime label: []const u8, update: device.display.Display.Update) !void {
                const encoded = try encodeDisplayPixelsBase64(self.allocator, update.pixels);
                errdefer self.allocator.free(encoded);

                self.mutex.lock();
                defer self.mutex.unlock();

                const seq = self.next_display_event_seq;
                self.next_display_event_seq += 1;
                const index = (seq - 1) % display_event_ring_size;
                if (self.display_events[index].pixels.len != 0) {
                    self.allocator.free(self.display_events[index].pixels);
                }
                self.display_events[index] = .{
                    .seq = seq,
                    .label = label,
                    .ts_ms = nowMs(),
                    .x = update.x,
                    .y = update.y,
                    .w = update.w,
                    .h = update.h,
                    .pixel_format = "rgb888",
                    .pixels = encoded,
                    .refresh_count = @intCast(update.refresh_count),
                };
            }

            fn writeDisplayEventsSince(
                self: *Self,
                allocator: gstd.runtime.std.mem.Allocator,
                writer: *Sse.Writer,
                last_seq: u64,
            ) !u64 {
                self.mutex.lock();
                defer self.mutex.unlock();

                const newest_seq = self.next_display_event_seq -| 1;
                if (newest_seq <= last_seq) return last_seq;

                const oldest_seq = if (newest_seq >= display_event_ring_size)
                    newest_seq - display_event_ring_size + 1
                else
                    1;
                var seq = @max(last_seq + 1, oldest_seq);
                while (seq <= newest_seq) : (seq += 1) {
                    const event = self.display_events[(seq - 1) % display_event_ring_size];
                    if (event.seq != seq) continue;
                    if (!(try writeJsonEvent(allocator, writer, "display.updated", .{
                        .label = event.label,
                        .ts_ms = event.ts_ms,
                        .x = event.x,
                        .y = event.y,
                        .w = event.w,
                        .h = event.h,
                        .pixel_format = event.pixel_format,
                        .pixels = event.pixels,
                        .refresh_count = event.refresh_count,
                    }))) return error.StreamClosed;
                }
                return newest_seq;
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
                const touch_point = touchPointFromQuery(args.query);
                const button_id = buttonIdFromQuery(args.query);
                const result = self.emit(args.path.gear_label, args.path.event, args.query.ts, metadata, touch_point, button_id) catch |err| {
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
                    .last_display_event_seq = self.currentDisplayEventSeq(),
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

            fn initAudioSystemDevices(allocator: gstd.runtime.std.mem.Allocator) ![audio_system_count]device.audio_system.AudioSystem {
                var systems: [audio_system_count]device.audio_system.AudioSystem = undefined;
                var initialized: usize = 0;
                errdefer {
                    for (0..initialized) |i| systems[i].deinit();
                }

                inline for (0..audio_system_count) |i| {
                    systems[i] = try device.audio_system.AudioSystem.init(allocator);
                    initialized += 1;
                }
                return systems;
            }

            fn deinitAudioSystemDevices(systems: *[audio_system_count]device.audio_system.AudioSystem) void {
                inline for (0..audio_system_count) |i| {
                    systems[i].deinit();
                }
            }

            fn initDisplayDevices(allocator: gstd.runtime.std.mem.Allocator) ![display_count]device.display.Display {
                var displays: [display_count]device.display.Display = undefined;
                var initialized: usize = 0;
                errdefer {
                    for (0..initialized) |i| displays[i].deinit();
                }

                inline for (0..display_count) |i| {
                    const periph = registries.display.periphs[i];
                    displays[i] = try device.display.Display.init(allocator, periph.width, periph.height);
                    initialized += 1;
                }
                return displays;
            }

            fn deinitDisplayDevices(displays: *[display_count]device.display.Display) void {
                inline for (0..display_count) |i| {
                    displays[i].deinit();
                }
            }

            fn deinitModemDevices(modems: *[modem_count]device.modem.Modem) void {
                inline for (0..modem_count) |i| {
                    modems[i].deinit();
                }
            }

            fn initWifiStaDevices(allocator: gstd.runtime.std.mem.Allocator) ![wifi_sta_count]device.wifi_sta.WifiSta {
                var wifi_stas: [wifi_sta_count]device.wifi_sta.WifiSta = undefined;
                var initialized: usize = 0;
                errdefer {
                    for (0..initialized) |i| wifi_stas[i].deinit();
                }

                inline for (0..wifi_sta_count) |i| {
                    wifi_stas[i] = try device.wifi_sta.WifiSta.init(allocator, defaultWifiStaConfig());
                    initialized += 1;
                }
                return wifi_stas;
            }

            fn deinitWifiStaDevices(wifi_stas: *[wifi_sta_count]device.wifi_sta.WifiSta) void {
                inline for (0..wifi_sta_count) |i| {
                    wifi_stas[i].deinit();
                }
            }

            fn makeInitConfig(
                allocator: gstd.runtime.std.mem.Allocator,
                audio_systems: *[audio_system_count]device.audio_system.AudioSystem,
                buttons: *[single_button_count]device.single_button.SingleButton,
                grouped_buttons: *[grouped_button_count]device.grouped_button.GroupedButton,
                displays: *[display_count]device.display.Display,
                modems: *[modem_count]device.modem.Modem,
                nfcs: *[nfc_count]device.nfc.Nfc,
                strips: *[ledstrip_count]device.ledstrip.LedStrip,
                touches: *[touch_count]device.touch.Touch,
                wifi_stas: *[wifi_sta_count]device.wifi_sta.WifiSta,
                bt_host: *if (has_bt_host) device.bt_host.BtHost else void,
            ) ZuxApp.InitConfig {
                var init_config: ZuxApp.InitConfig = undefined;
                if (@hasField(ZuxApp.InitConfig, "custom_pipeline_node")) {
                    init_config.custom_pipeline_node = null;
                }
                init_config.allocator = allocator;
                if (@hasField(ZuxApp.InitConfig, "pipeline_config")) {
                    init_config.pipeline_config = .{};
                }
                if (@hasField(ZuxApp.InitConfig, "poller_config")) {
                    init_config.poller_config = .{};
                }
                if (@hasField(ZuxApp.InitConfig, "initial_state") and !@hasDecl(AppHost, "initialStateProvidedByLauncher")) {
                    init_config.initial_state = defaultInitialState(@FieldType(ZuxApp.InitConfig, "initial_state"));
                }
                if (comptime has_bt_host) {
                    const BtHostType = @FieldType(ZuxApp.InitConfig, "bt");
                    if (BtHostType == embed.bt.Host) {
                        init_config.bt = bt_host.handle();
                    } else {
                        @compileError("desktop ZuxServer bt field must use bt.Host");
                    }
                }

                inline for (0..single_button_count) |i| {
                    const periph = registries.single_button.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    if (@hasField(ZuxApp.InitConfig, label_name)) {
                        const ButtonType = @FieldType(ZuxApp.InitConfig, label_name);
                        if (ButtonType == embed.drivers.button.Single) {
                            @field(init_config, label_name) = embed.drivers.button.Single.init(device.single_button.SingleButton, &buttons[i]);
                        } else {
                            @compileError("desktop ZuxServer button/single field must use drivers.button.Single");
                        }
                    }
                }

                inline for (0..grouped_button_count) |i| {
                    const periph = registries.adc_button.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    if (@hasField(ZuxApp.InitConfig, label_name)) {
                        const ButtonType = @FieldType(ZuxApp.InitConfig, label_name);
                        if (ButtonType == embed.drivers.button.Grouped) {
                            @field(init_config, label_name) = embed.drivers.button.Grouped.init(device.grouped_button.GroupedButton, &grouped_buttons[i]);
                        } else {
                            @compileError("desktop ZuxServer button/grouped field must use drivers.button.Grouped");
                        }
                    }
                }

                inline for (0..ledstrip_count) |i| {
                    const periph = registries.ledstrip.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = strips[i].handle();
                }

                inline for (0..display_count) |i| {
                    const periph = registries.display.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = displays[i].handle();
                }

                inline for (0..modem_count) |i| {
                    const periph = registries.modem.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    const ModemType = @FieldType(ZuxApp.InitConfig, label_name);
                    if (ModemType == embed.drivers.Modem) {
                        @field(init_config, label_name) = modems[i].handle();
                    } else {
                        @compileError("desktop ZuxServer modem field must use drivers.Modem");
                    }
                }

                inline for (0..nfc_count) |i| {
                    const periph = registries.nfc.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    const NfcType = @FieldType(ZuxApp.InitConfig, label_name);
                    if (NfcType == embed.nfc.Reader) {
                        @field(init_config, label_name) = nfcs[i].handle();
                    } else {
                        @compileError("desktop ZuxServer nfc field must use nfc.Reader");
                    }
                }

                inline for (0..touch_count) |i| {
                    const periph = registries.touch.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    @field(init_config, label_name) = touches[i].handle();
                }

                inline for (0..audio_system_count) |i| {
                    const periph = registries.audio_system.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    const AudioSystemType = @FieldType(ZuxApp.InitConfig, label_name);
                    if (AudioSystemType == *device.audio_system.AudioSystem) {
                        @field(init_config, label_name) = &audio_systems[i];
                    } else {
                        @compileError("desktop ZuxServer audio_system field must use *desktop.device.audio_system.AudioSystem");
                    }
                }

                inline for (0..wifi_sta_count) |i| {
                    const periph = registries.wifi_sta.periphs[i];
                    const label_name = comptime labelText(periph.label);
                    const WifiStaType = @FieldType(ZuxApp.InitConfig, label_name);
                    if (WifiStaType == embed.drivers.wifi.Sta) {
                        @field(init_config, label_name) = wifi_stas[i].handle();
                    } else {
                        @compileError("desktop ZuxServer wifi_sta field must use drivers.wifi.Sta");
                    }
                }

                return init_config;
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

fn validateLauncher(comptime Launcher: type) void {
    if (!@hasDecl(Launcher, "AppHost")) @compileError("desktop ZuxServer requires Launcher.AppHost");
    if (!@hasDecl(Launcher, "ZuxApp")) @compileError("desktop ZuxServer requires Launcher.ZuxApp");
    if (!@hasDecl(Launcher, "InitConfig")) @compileError("desktop ZuxServer requires Launcher.InitConfig");
    if (!@hasDecl(Launcher, "StartConfig")) @compileError("desktop ZuxServer requires Launcher.StartConfig");
    if (!@hasDecl(Launcher, "Allocator")) @compileError("desktop ZuxServer requires Launcher.Allocator");

    const ZuxApp = Launcher.ZuxApp;
    if (Launcher.AppHost.ZuxApp != ZuxApp) @compileError("desktop ZuxServer requires Launcher.AppHost.ZuxApp to match Launcher.ZuxApp");
    if (Launcher.InitConfig != ZuxApp.InitConfig) @compileError("desktop ZuxServer requires Launcher.InitConfig to match ZuxApp.InitConfig");
    if (Launcher.StartConfig != ZuxApp.StartConfig) @compileError("desktop ZuxServer requires Launcher.StartConfig to match ZuxApp.StartConfig");
    if (Launcher.Allocator != gstd.runtime.std.mem.Allocator) @compileError("desktop ZuxServer requires Launcher.Allocator to match gstd allocator");

    _ = @as(*const fn (Launcher.Allocator, ZuxApp.InitConfig) anyerror!Launcher, &Launcher.init);
    _ = @as(*const fn (*Launcher) void, &Launcher.deinit);
    _ = @as(*const fn (*Launcher) *Launcher.AppHost, &Launcher.app);
    _ = @as(*const fn (*Launcher) *ZuxApp, &Launcher.zux);

    if (!@hasDecl(ZuxApp, "registries")) @compileError("desktop ZuxServer requires ZuxApp.registries");
    if (!@hasDecl(ZuxApp, "InitConfig")) @compileError("desktop ZuxServer requires ZuxApp.InitConfig");
    if (!@hasDecl(ZuxApp, "StartConfig")) @compileError("desktop ZuxServer requires ZuxApp.StartConfig");
    if (!@hasDecl(ZuxApp, "PeriphLabel")) @compileError("desktop ZuxServer requires ZuxApp.PeriphLabel");
    _ = @as(*const fn (*ZuxApp) void, &ZuxApp.deinit);
    _ = @as(*const fn (*ZuxApp, ZuxApp.StartConfig) anyerror!void, &ZuxApp.start);
    _ = @as(*const fn (*ZuxApp) anyerror!void, &ZuxApp.stop);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel) anyerror!void, &ZuxApp.press_single_button);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel) anyerror!void, &ZuxApp.release_single_button);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel, u32) anyerror!void, &ZuxApp.press_grouped_button);
    _ = @as(*const fn (*ZuxApp, ZuxApp.PeriphLabel) anyerror!void, &ZuxApp.release_grouped_button);

    const registries = ZuxApp.registries;
    if (registries.imu.len != 0) @compileError("desktop ZuxServer does not support imu yet");
    if (registries.wifi_ap.len != 0) @compileError("desktop ZuxServer does not support wifi ap yet");
}

fn appTitle(comptime ZuxAppHost: type) []const u8 {
    if (@hasDecl(ZuxAppHost, "title")) {
        return ZuxAppHost.title;
    }
    return "desktop runtime";
}

fn appDescription(comptime ZuxAppHost: type) []const u8 {
    if (@hasDecl(ZuxAppHost, "description")) {
        return ZuxAppHost.description;
    }
    return "Local input and output runtime over GET and SSE.";
}

fn isVirtualButton(comptime periph: anytype) bool {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "input_type")) {
        return periph.input_type == .virtual;
    }
    return false;
}

fn exposedButtonCount(comptime registry: anytype) usize {
    comptime var count: usize = 0;
    inline for (0..registry.len) |i| {
        if (!isVirtualButton(registry.periphs[i])) {
            count += 1;
        }
    }
    return count;
}

fn labelText(comptime label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(label))) {
        .enum_literal => @tagName(label),
        .@"enum" => @tagName(label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => label[0..],
                else => @compileError("desktop ZuxServer label must be an enum literal, enum value, or []const u8"),
            },
            else => @compileError("desktop ZuxServer label must be an enum literal, enum value, or []const u8"),
        },
        .array => label[0..],
        else => @compileError("desktop ZuxServer label must be an enum literal, enum value, or []const u8"),
    };
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

fn writeSseHeartbeat(writer: *Sse.Writer) bool {
    writer.event(.{
        .event = "ping",
        .data = "",
    }) catch return false;
    writer.flush() catch return false;
    return true;
}

fn touchPointFromQuery(query: anytype) ?TouchPointQuery {
    if (comptime !@hasField(@TypeOf(query), "x") or !@hasField(@TypeOf(query), "y")) {
        return null;
    }

    const x = query.x orelse return null;
    const y = query.y orelse return null;
    return .{
        .x = intToU16Saturated(x),
        .y = intToU16Saturated(y),
    };
}

fn buttonIdFromQuery(query: anytype) ?u32 {
    if (comptime !@hasField(@TypeOf(query), "button_id")) {
        return null;
    }

    const button_id = query.button_id orelse return null;
    return std.math.cast(u32, button_id);
}

fn intToU16Saturated(value: anytype) u16 {
    if (value <= 0) return 0;
    if (value > std.math.maxInt(u16)) return std.math.maxInt(u16);
    return @intCast(value);
}

fn defaultWifiStaConfig() device.wifi_sta.Config {
    var config: device.wifi_sta.Config = .{};
    if (@hasField(device.wifi_sta.Config, "request_location_authorization")) {
        config.request_location_authorization = true;
    }
    return config;
}

fn wifiStaStateText(state: embed.drivers.wifi.Sta.State) []const u8 {
    return switch (state) {
        .idle => "idle",
        .scanning => "scanning",
        .connecting => "connecting",
        .connected => "connected",
    };
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

fn encodeDisplayPixelsBase64(allocator: gstd.runtime.std.mem.Allocator, source: []const embed.drivers.Display.Rgb) ![]u8 {
    const raw = try allocator.alloc(u8, source.len * 3);
    defer allocator.free(raw);

    for (source, 0..) |pixel, index| {
        const base = index * 3;
        raw[base] = pixel.r;
        raw[base + 1] = pixel.g;
        raw[base + 2] = pixel.b;
    }

    const encoded = try allocator.alloc(u8, gstd.runtime.std.base64.standard.Encoder.calcSize(raw.len));
    _ = gstd.runtime.std.base64.standard.Encoder.encode(encoded, raw);
    return encoded;
}

fn makeErrorResponse(code: []const u8, message: []const u8) api.Models.ErrorResponse {
    return @as(api.Models.ErrorResponse, .{
        .error_ = .{
            .code = code,
            .message = message,
        },
    });
}

fn defaultInitialState(comptime InitialState: type) InitialState {
    var initial_state: InitialState = undefined;
    inline for (@typeInfo(InitialState).@"struct".fields) |field| {
        @field(initial_state, field.name) = defaultValue(field.type);
    }
    return initial_state;
}

fn defaultValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var value: T = undefined;
            inline for (info.fields) |field| {
                @field(value, field.name) = if (field.default_value_ptr) |ptr|
                    defaultFieldValue(field.type, ptr)
                else
                    defaultValue(field.type);
            }
            break :blk value;
        },
        .@"enum" => |info| @enumFromInt(info.fields[0].value),
        .bool => false,
        .int => 0,
        .float => 0,
        .optional => null,
        .array => |info| blk: {
            var value: T = undefined;
            for (&value) |*item| {
                item.* = defaultValue(info.child);
            }
            break :blk value;
        },
        else => @compileError("desktop ZuxServer cannot synthesize default value for " ++ @typeName(T)),
    };
}

fn defaultFieldValue(comptime T: type, ptr: *const anyopaque) T {
    const typed: *const T = @ptrCast(@alignCast(ptr));
    return typed.*;
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

pub fn TestRunner(comptime std_api: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const BuiltApp = comptime blk: {
        const AssemblerType = embed.zux.assemble(gstd.runtime, .{
            .max_adc_buttons = 1,
            .max_displays = 1,
            .max_modem = 1,
            .max_nfc = 1,
        });
        var assembler = AssemblerType.init();
        assembler.addGroupedButtonWithMetadata("buttons", 7, .{
            .label_text = "Buttons",
            .item_label_texts = &.{ "Red", "Green", "Blue" },
        }, 3);
        assembler.addDisplayWithMetadataAndSize("screen", 9, .{
            .label_text = "Screen",
        }, 128, 64);
        assembler.addModemWithMetadata("modem", 11, .{
            .label_text = "Cellular",
        });
        assembler.addNfcWithMetadata("nfc", 13, .{
            .label_text = "NFC",
        });

        const BuildConfig = assembler.BuildConfig();
        const build_config: BuildConfig = .{
            .buttons = embed.drivers.button.Grouped,
            .screen = embed.drivers.Display,
            .modem = embed.drivers.Modem,
            .nfc = embed.nfc.Reader,
        };
        break :blk assembler.build(build_config);
    };

    const TestLauncher = struct {
        pub const ZuxApp = BuiltApp;
        pub const InitConfig = ZuxApp.InitConfig;
        pub const StartConfig = ZuxApp.StartConfig;
        pub const Allocator = gstd.runtime.std.mem.Allocator;
        pub const AppHost = struct {
            pub const ZuxApp = BuiltApp;
            pub const title = "topology test";
            pub const description = "metadata topology test";
        };

        app_host: AppHost = .{},
        zux_app: ZuxApp,

        pub fn init(_: Allocator, init_config: InitConfig) !@This() {
            return .{
                .zux_app = try ZuxApp.init(init_config),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.zux_app.deinit();
        }

        pub fn app(self: *@This()) *AppHost {
            return &self.app_host;
        }

        pub fn zux(self: *@This()) *ZuxApp {
            return &self.zux_app;
        }
    };

    const Server = make(TestLauncher);

    const TestCase = struct {
        fn topologyIncludesComponentMetadata(allocator: std_api.mem.Allocator) !void {
            var runtime: Server.RuntimeState = undefined;
            try runtime.init(allocator, .{ .ticker = .manual });
            defer runtime.deinit();

            const topology = try runtime.makeTopologyResponse(allocator);
            defer allocator.free(topology.gears);

            try std_api.testing.expectEqualStrings("topology test", topology.title);
            try std_api.testing.expectEqual(@as(usize, 4), topology.gears.len);
            try expectGear(topology.gears[0], "grouped_button", "buttons", null, 3, null, null, null, "Buttons", &.{ "Red", "Green", "Blue" });
            try expectGear(topology.gears[1], "display", "screen", null, null, 128, 64, null, "Screen", &.{});
            try expectGear(topology.gears[2], "modem", "modem", null, null, null, null, null, "Cellular", &.{});
            try expectGear(topology.gears[3], "nfc", "nfc", null, null, null, null, null, "NFC", &.{});
        }

        fn groupedButtonEmitUpdatesState(allocator: std_api.mem.Allocator) !void {
            var runtime: Server.RuntimeState = undefined;
            try runtime.init(allocator, .{ .ticker = .manual });
            defer runtime.deinit();

            _ = try runtime.emit("buttons", "press", 123, null, null, 2);
            var pressed = try runtime.makeStateResponse(allocator, 124);
            defer Server.RuntimeState.deinitStateResponse(allocator, &pressed);

            try std_api.testing.expectEqual(@as(usize, 2), pressed.gears.len);
            switch (pressed.gears[0]) {
                .GroupedButtonState => |state| {
                    try std_api.testing.expectEqualStrings("buttons", state.label);
                    try std_api.testing.expectEqual(@as(i64, 2), state.pressed_button_id.?);
                },
                else => return error.ExpectedGroupedButtonState,
            }

            _ = try runtime.emit("buttons", "release", 125, null, null, null);
            var released = try runtime.makeStateResponse(allocator, 126);
            defer Server.RuntimeState.deinitStateResponse(allocator, &released);

            switch (released.gears[0]) {
                .GroupedButtonState => |state| {
                    try std_api.testing.expect(state.pressed_button_id == null);
                },
                else => return error.ExpectedGroupedButtonState,
            }

            try std_api.testing.expectError(
                Server.RuntimeState.EmitError.InvalidEvent,
                runtime.emit("buttons", "press", 127, null, null, 3),
            );
        }

        fn expectGear(
            gear: api.Models.GearTopology,
            expected_kind: []const u8,
            expected_label: []const u8,
            expected_pixel_count: ?i64,
            expected_button_count: ?i64,
            expected_width: ?i64,
            expected_height: ?i64,
            expected_target: ?[]const u8,
            expected_label_text: ?[]const u8,
            expected_item_labels: []const []const u8,
        ) !void {
            try std_api.testing.expectEqualStrings(expected_kind, gear.kind);
            try std_api.testing.expectEqualStrings(expected_label, gear.label);
            try std_api.testing.expectEqual(expected_pixel_count, gear.pixel_count);
            try std_api.testing.expectEqual(expected_button_count, gear.button_count);
            try std_api.testing.expectEqual(expected_width, gear.width);
            try std_api.testing.expectEqual(expected_height, gear.height);
            if (expected_target) |target| {
                try std_api.testing.expectEqualStrings(target, gear.target.?);
            } else {
                try std_api.testing.expect(gear.target == null);
            }
            if (expected_label_text) |label_text| {
                const metadata = gear.metadata.?;
                try std_api.testing.expectEqualStrings(label_text, metadata.label_text.?);
                const item_labels = metadata.item_label_texts orelse &.{};
                try std_api.testing.expectEqual(expected_item_labels.len, item_labels.len);
                for (expected_item_labels, item_labels) |expected, actual| {
                    try std_api.testing.expectEqualStrings(expected, actual);
                }
            } else {
                try std_api.testing.expect(gear.metadata == null);
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std_api.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std_api.mem.Allocator) bool {
            _ = self;

            TestCase.topologyIncludesComponentMetadata(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.groupedButtonEmitUpdatesState(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std_api.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
