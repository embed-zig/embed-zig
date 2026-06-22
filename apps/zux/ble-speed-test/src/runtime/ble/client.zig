const embed = @import("embed");
const glib = @import("glib");

const consts = @import("../../consts.zig");
const speed_test = @import("../../reducers/speed_test.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const bt = embed.bt;
    const Mutex = grt.sync.Mutex;
    const Condition = grt.sync.Condition;
    const AtomicBool = grt.std.atomic.Value(bool);
    const log = grt.std.log.scoped(.ble_speed_client);

    return struct {
        const Self = @This();

        allocator: glib.std.mem.Allocator,
        host: bt.Host,
        app: *ZuxAppType,
        task_options: glib.task.Options,
        stop_requested: AtomicBool = AtomicBool.init(false),
        task: ?grt.task.Handle = null,
        mutex: Mutex = .{},
        cond: Condition = .{},
        found: ?bt.Central.AdvReport = null,
        conn_handle: u16 = 0,
        rx_synced: bool = false,
        rx_expected_seq: u32 = 0,
        rx_window_bytes: u32 = 0,
        rx_window_packets: u32 = 0,
        rx_window_lost_packets: u32 = 0,
        rx_window_reordered_packets: u32 = 0,

        const source_id = ZuxAppType.ImplType.sourceId(.bt);
        const window_ms: u32 = 1000;
        const reconnect_sleep_ns = 500 * glib.time.duration.MilliSecond;
        const tx_pace_ns = glib.time.duration.MilliSecond;
        const backpressure_sleep_ns = 5 * glib.time.duration.MilliSecond;
        const preferred_conn_interval_min: u16 = 0x0006;
        const preferred_conn_interval_max: u16 = 0x000C;

        pub fn init(allocator: glib.std.mem.Allocator, host: bt.Host, app: *ZuxAppType, task_options: glib.task.Options) !Self {
            return .{
                .allocator = allocator,
                .host = host,
                .app = app,
                .task_options = task_options,
            };
        }

        pub fn start(self: *Self) !void {
            self.stop_requested.store(false, .release);
            log.debug("starting client runtime", .{});
            self.task = try grt.task.go(
                "zux/ble_speed/client",
                self.task_options,
                glib.task.Routine.init(self, threadMain),
            );
        }

        pub fn stop(self: *Self) void {
            self.stop_requested.store(true, .release);
            self.cond.broadcast();
            if (self.task) |task| {
                task.join();
                self.task = null;
            }
        }

        fn threadMain(self: *Self) void {
            self.loop() catch |err| self.publishError(err);
        }

        fn shouldStop(self: *Self) bool {
            return self.stop_requested.load(.acquire);
        }

        fn loop(self: *Self) !void {
            log.debug("client loop starting", .{});
            var central = self.host.central();
            central.addEventHook(self, onCentralEvent);
            defer central.removeEventHook(self, onCentralEvent);
            defer central.stop();

            try central.start();

            while (!self.shouldStop()) {
                try self.dispatchStop(0);
                self.clearFound();
                central.startScanning(.{
                    .active = true,
                    .filter_duplicates = false,
                    .service_uuids = &.{consts.service_uuid},
                }) catch |err| {
                    try self.dispatchErrorFrom(err);
                    self.restartCentral(&central, "scan failed");
                    grt.time.sleep(reconnect_sleep_ns);
                    continue;
                };

                const report = self.waitFound() orelse {
                    central.stopScanning();
                    continue;
                };
                central.stopScanning();

                try self.dispatchCentralFound(report);
                const info = central.connect(report.addr, report.addr_type, .{
                    .interval_min = preferred_conn_interval_min,
                    .interval_max = preferred_conn_interval_max,
                }) catch |err| {
                    log.err("connect failed: {s}", .{@errorName(err)});
                    try self.dispatchErrorFrom(err);
                    self.restartCentral(&central, "connect failed");
                    grt.time.sleep(reconnect_sleep_ns);
                    continue;
                };
                self.setConnHandle(info.conn_handle);
                try self.dispatchCentralConnected(info);

                _ = central.exchangeMtu(info.conn_handle, consts.target_mtu) catch |err| {
                    log.debug("mtu exchange not explicit on this backend: {s}", .{@errorName(err)});
                };
                const speed_chars = resolveSpeedChars(central, info.conn_handle) catch |err| {
                    log.err("resolve speed chars failed: {s}", .{@errorName(err)});
                    try self.dispatchErrorFrom(err);
                    try self.closeSession(central, info.conn_handle, "resolve chars failed");
                    continue;
                };
                central.subscribe(info.conn_handle, speed_chars.tx.cccd_handle) catch |err| {
                    log.err("subscribe failed: {s}", .{@errorName(err)});
                    try self.dispatchErrorFrom(err);
                    try self.closeSession(central, info.conn_handle, "subscribe failed");
                    continue;
                };
                const att_mtu = central.getAttMtu(info.conn_handle);
                log.info("client using ATT MTU estimate {}", .{att_mtu});
                try self.dispatchReady(info.conn_handle, info.interval, att_mtu);
                try self.dispatchStart(info.conn_handle);

                self.runTxLoop(central, info.conn_handle, speed_chars.rx.value_handle, att_mtu) catch |err| {
                    if (self.isConnActive(info.conn_handle)) {
                        try self.dispatchErrorFrom(err);
                        try self.closeSession(central, info.conn_handle, @errorName(err));
                    }
                };

                if (self.isConnActive(info.conn_handle)) {
                    try self.closeSession(central, info.conn_handle, "tx loop ended");
                }
            }
        }

        fn restartCentral(self: *Self, central: *bt.Central, reason: []const u8) void {
            log.info("client restart central reason={s}", .{reason});
            self.setConnHandle(0);
            central.stop();
            central.start() catch |err| {
                log.err("client restart central failed: {s}", .{@errorName(err)});
                self.dispatchErrorFrom(err) catch {};
            };
        }

        fn closeSession(self: *Self, central: bt.Central, conn_handle: u16, reason: []const u8) !void {
            log.info("client close session conn={} reason={s}", .{ conn_handle, reason });
            self.setConnHandle(0);
            try self.dispatchStop(conn_handle);
            try self.dispatchCentralDisconnected(conn_handle);
            log.info("client disconnect begin conn={}", .{conn_handle});
            central.disconnect(conn_handle);
            log.info("client disconnect end conn={}", .{conn_handle});
        }

        fn runTxLoop(self: *Self, central: bt.Central, conn_handle: u16, value_handle: u16, att_mtu: u16) !void {
            var seq: u32 = 0;
            var tx_bytes: u32 = 0;
            var tx_packets: u32 = 0;
            var rx_window: RxWindow = .{};
            var last_window = grt.time.instant.now();
            var packet_buf: [consts.max_payload_len + consts.Header.encoded_len]u8 = undefined;
            const value_payload_len = packetPayloadLenForAttMtu(att_mtu);

            while (!self.shouldStop() and self.isConnActive(conn_handle)) {
                const packet = makePacket(&packet_buf, seq, value_payload_len);
                central.gattWriteNoResp(conn_handle, value_handle, packet) catch |err| switch (err) {
                    error.Timeout => {
                        log.info("client write backpressure conn={} seq={} err={s}", .{ conn_handle, seq, @errorName(err) });
                        grt.time.sleep(backpressure_sleep_ns);
                        continue;
                    },
                    else => {
                        log.info("client write stopped conn={} seq={} err={s}", .{ conn_handle, seq, @errorName(err) });
                        return err;
                    },
                };
                seq +%= 1;
                tx_bytes +|= @intCast(packet.len);
                tx_packets +|= 1;

                const rx_snapshot = self.takeRxWindow();
                rx_window.bytes +|= rx_snapshot.bytes;
                rx_window.packets +|= rx_snapshot.packets;
                rx_window.expected_seq = rx_snapshot.expected_seq;
                rx_window.lost_packets +|= rx_snapshot.lost_packets;
                rx_window.reordered_packets +|= rx_snapshot.reordered_packets;

                const now = grt.time.instant.now();
                if (now - last_window >= window_ms * glib.time.duration.MilliSecond) {
                    try self.dispatchStatsWindow(tx_bytes, rx_window, tx_packets);
                    tx_bytes = 0;
                    tx_packets = 0;
                    rx_window = .{};
                    last_window = now;
                }

                grt.time.sleep(tx_pace_ns);
            }
        }

        fn onCentralEvent(ctx: ?*anyopaque, event: bt.Central.Event) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .device_found => |report| {
                    if (!matchesTarget(report)) return;
                    self.mutex.lock();
                    self.found = report;
                    self.cond.signal();
                    self.mutex.unlock();
                },
                .notification => |notif| self.noteRxPacket(notif.payload()),
                .disconnected => |conn_handle| {
                    self.setConnHandle(0);
                    self.dispatchStop(conn_handle) catch {};
                    self.dispatchCentralDisconnected(conn_handle) catch {};
                },
                .connected => |info| {
                    self.setConnHandle(info.conn_handle);
                    self.dispatchCentralConnected(info) catch {};
                },
                .connection_updated => |info| {
                    log.info("client connection updated conn={} interval={} latency={}", .{ info.conn_handle, info.interval, info.latency });
                    self.dispatchCentralConnectionUpdated(info) catch {};
                },
            }
        }

        fn clearFound(self: *Self) void {
            self.mutex.lock();
            self.found = null;
            self.mutex.unlock();
        }

        fn waitFound(self: *Self) ?bt.Central.AdvReport {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.found == null and !self.shouldStop()) {
                self.cond.timedWait(&self.mutex, 2 * glib.time.duration.Second) catch {};
            }
            return self.found;
        }

        fn setConnHandle(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            if (self.conn_handle != conn_handle) self.resetRxTrackingLocked();
            self.conn_handle = conn_handle;
            self.mutex.unlock();
        }

        fn isConnActive(self: *Self, conn_handle: u16) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.conn_handle == conn_handle;
        }

        fn noteRxPacket(self: *Self, data: []const u8) void {
            const seq = packetSeq(data) orelse return;
            self.mutex.lock();
            if (!self.rx_synced) {
                self.rx_synced = true;
                self.rx_expected_seq = seq +% 1;
            } else if (seq == self.rx_expected_seq) {
                self.rx_expected_seq +%= 1;
            } else if (seq > self.rx_expected_seq) {
                self.rx_window_lost_packets +|= seq - self.rx_expected_seq;
                self.rx_expected_seq = seq +% 1;
            } else {
                self.rx_window_reordered_packets +|= 1;
            }
            self.rx_window_bytes +|= @intCast(data.len);
            self.rx_window_packets +|= 1;
            self.mutex.unlock();
        }

        fn resetRxTrackingLocked(self: *Self) void {
            self.rx_synced = false;
            self.rx_expected_seq = 0;
            self.rx_window_bytes = 0;
            self.rx_window_packets = 0;
            self.rx_window_lost_packets = 0;
            self.rx_window_reordered_packets = 0;
        }

        const RxWindow = struct {
            bytes: u32 = 0,
            packets: u32 = 0,
            expected_seq: u32 = 0,
            lost_packets: u32 = 0,
            reordered_packets: u32 = 0,
        };

        fn takeRxWindow(self: *Self) RxWindow {
            self.mutex.lock();
            defer self.mutex.unlock();
            const snapshot: RxWindow = .{
                .bytes = self.rx_window_bytes,
                .packets = self.rx_window_packets,
                .expected_seq = self.rx_expected_seq,
                .lost_packets = self.rx_window_lost_packets,
                .reordered_packets = self.rx_window_reordered_packets,
            };
            self.rx_window_bytes = 0;
            self.rx_window_packets = 0;
            self.rx_window_lost_packets = 0;
            self.rx_window_reordered_packets = 0;
            return snapshot;
        }

        fn dispatchCentralFound(self: *Self, report: bt.Central.AdvReport) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_central_found = .{
                    .source_id = source_id,
                    .peer_addr = report.addr,
                    .rssi = report.rssi,
                    .name_end = @intCast(@min(report.name_len, report.name.len)),
                    .name_buf = report.name,
                    .adv_data_end = @intCast(@min(report.data_len, report.data.len)),
                    .adv_data_buf = report.data,
                } },
            });
        }

        fn dispatchCentralConnected(self: *Self, info: bt.Central.ConnectionInfo) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_central_connected = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .supervision_timeout = info.supervision_timeout,
                } },
            });
        }

        fn dispatchCentralConnectionUpdated(self: *Self, info: bt.Central.ConnectionInfo) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_central_connection_updated = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .supervision_timeout = info.supervision_timeout,
                } },
            });
        }

        fn dispatchCentralDisconnected(self: *Self, conn_handle: u16) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_central_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                } },
            });
        }

        fn dispatchCustom(self: *Self, comptime EventType: type, payload: *EventType) !void {
            errdefer payload.deinit();
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .custom = self.app.initCustomEvent(EventType, source_id, payload) },
            });
        }

        fn dispatchStart(self: *Self, conn_handle: u16) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .start);
            event.role = .client;
            event.conn_handle = conn_handle;
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchReady(self: *Self, conn_handle: u16, conn_interval: u16, att_mtu: u16) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .ready);
            event.role = .client;
            event.conn_handle = conn_handle;
            event.conn_interval = conn_interval;
            event.att_mtu = att_mtu;
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchStop(self: *Self, conn_handle: u16) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .stop);
            event.role = .client;
            event.conn_handle = conn_handle;
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchStatsWindow(self: *Self, tx_bytes: u32, rx: RxWindow, tx_packets: u32) !void {
            const event = try speed_test.StatsDeltaEvent.init(self.allocator);
            event.tx_bytes = tx_bytes;
            event.rx_bytes = rx.bytes;
            event.tx_packets = tx_packets;
            event.rx_packets = rx.packets;
            event.rx_expected_seq = rx.expected_seq;
            event.rx_lost_packets = rx.lost_packets;
            event.rx_reordered_packets = rx.reordered_packets;
            event.window_ms = window_ms;
            try self.dispatchCustom(speed_test.StatsDeltaEvent, event);
        }

        fn dispatchError(self: *Self, err: anyerror) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .fail);
            event.role = .client;
            event.error_code = errorCode(err);
            setErrorName(event, @errorName(err));
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchErrorFrom(self: *Self, err: anyerror) !void {
            const code = errorCode(err);
            log.err("client fail err={s} code={}", .{ @errorName(err), code });
            try self.dispatchError(err);
        }

        fn publishError(self: *Self, err: anyerror) void {
            self.dispatchErrorFrom(err) catch {};
        }

        fn matchesTarget(report: bt.Central.AdvReport) bool {
            return advHasService(report.getData(), consts.service_uuid);
        }

        const SpeedChars = struct {
            tx: bt.Central.DiscoveredChar,
            rx: bt.Central.DiscoveredChar,
        };

        fn resolveSpeedChars(central: bt.Central, conn_handle: u16) bt.Central.GattError!SpeedChars {
            var services_buf: [16]bt.Central.DiscoveredService = undefined;
            const service_count = try central.discoverServices(conn_handle, &services_buf);

            var service: ?bt.Central.DiscoveredService = null;
            for (services_buf[0..service_count]) |svc| {
                log.debug("service uuid=0x{x} start={} end={}", .{ svc.uuid, svc.start_handle, svc.end_handle });
                if (svc.uuid == consts.service_uuid) service = svc;
            }
            const speed_service = service orelse return error.AttError;

            var chars_buf: [16]bt.Central.DiscoveredChar = undefined;
            const char_count = try central.discoverChars(conn_handle, speed_service.start_handle, speed_service.end_handle, &chars_buf);

            var tx: ?bt.Central.DiscoveredChar = null;
            var rx: ?bt.Central.DiscoveredChar = null;
            for (chars_buf[0..char_count]) |ch| {
                log.debug("char uuid=0x{x} decl={} value={} cccd={} props=0x{x}", .{
                    ch.uuid,
                    ch.decl_handle,
                    ch.value_handle,
                    ch.cccd_handle,
                    ch.properties,
                });
                if (ch.uuid == consts.tx_char_uuid) tx = ch;
                if (ch.uuid == consts.rx_char_uuid) rx = ch;
            }

            return .{
                .tx = tx orelse return error.AttError,
                .rx = rx orelse return error.AttError,
            };
        }

        fn advHasService(data: []const u8, uuid: u16) bool {
            var i: usize = 0;
            while (i < data.len) {
                const len = data[i];
                if (len == 0) break;
                if (i + 1 + len > data.len) break;
                const typ = data[i + 1];
                const payload = data[i + 2 .. i + 1 + len];
                if (typ == 0x02 or typ == 0x03) {
                    var j: usize = 0;
                    while (j + 1 < payload.len) : (j += 2) {
                        if (glib.std.mem.readInt(u16, payload[j..][0..2], .little) == uuid) return true;
                    }
                }
                i += 1 + len;
            }
            return false;
        }

        fn packetPayloadLenForAttMtu(att_mtu: u16) usize {
            if (att_mtu <= consts.att_header_len + consts.Header.encoded_len) return 1;
            return @intCast(@min(att_mtu - consts.att_header_len - consts.Header.encoded_len, consts.max_payload_len));
        }

        fn makePacket(buf: []u8, seq: u32, value_len: usize) []const u8 {
            const payload_len = @min(value_len, consts.max_payload_len);
            const total_len = consts.Header.encoded_len + payload_len;
            glib.std.mem.writeInt(u16, buf[0..2], consts.Header.magic_value, .little);
            buf[2] = @intFromEnum(consts.PacketKind.data);
            buf[3] = 0;
            glib.std.mem.writeInt(u32, buf[4..8], seq, .little);
            glib.std.mem.writeInt(u32, buf[8..12], 0, .little);
            glib.std.mem.writeInt(u16, buf[12..14], @intCast(payload_len), .little);
            for (buf[consts.Header.encoded_len..total_len], 0..) |*byte, i| {
                byte.* = @truncate(seq +% @as(u32, @intCast(i)));
            }
            return buf[0..total_len];
        }

        fn packetSeq(data: []const u8) ?u32 {
            if (data.len < consts.Header.encoded_len) return null;
            if (glib.std.mem.readInt(u16, data[0..2], .little) != consts.Header.magic_value) return null;
            if (data[2] != @intFromEnum(consts.PacketKind.data)) return null;
            return glib.std.mem.readInt(u32, data[4..8], .little);
        }

        fn errorCode(err: anyerror) u32 {
            return @intFromError(err);
        }

        fn setErrorName(event: *speed_test.ActionEvent, name: []const u8) void {
            const n = @min(event.error_name_buf.len, name.len);
            @memcpy(event.error_name_buf[0..n], name[0..n]);
            if (n < event.error_name_buf.len) @memset(event.error_name_buf[n..], 0);
            event.error_name_len = @intCast(n);
        }
    };
}
