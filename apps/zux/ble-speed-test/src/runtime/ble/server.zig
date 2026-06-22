const embed = @import("embed");
const glib = @import("glib");

const consts = @import("../../consts.zig");
const speed_test = @import("../../reducers/speed_test.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const bt = embed.bt;
    const Mutex = grt.sync.Mutex;
    const AcceptChannel = grt.sync.Channel(u16);
    const AtomicBool = grt.std.atomic.Value(bool);
    const log = grt.std.log.scoped(.ble_speed_server);

    return struct {
        const Self = @This();

        allocator: glib.std.mem.Allocator,
        host: bt.Host,
        app: *ZuxAppType,
        task_options: glib.task.Options,
        stop_requested: AtomicBool = AtomicBool.init(false),
        task: ?grt.task.Handle = null,
        accept_ch: AcceptChannel,
        accept_alive: bool = true,
        mutex: Mutex = .{},
        conn_handle: u16 = 0,
        att_mtu: u16 = bt.Central.DEFAULT_ATT_MTU,
        rx_synced: bool = false,
        rx_expected_seq: u32 = 0,
        rx_window_bytes: u32 = 0,
        rx_window_packets: u32 = 0,
        rx_window_lost_packets: u32 = 0,
        rx_window_reordered_packets: u32 = 0,
        last_zero_rx_log: glib.time.instant.Time = 0,

        const source_id = ZuxAppType.ImplType.sourceId(.bt);
        const window_ms: u32 = 1000;
        const reconnect_sleep_ns = 500 * glib.time.duration.MilliSecond;
        const tx_pace_ns = glib.time.duration.MilliSecond;
        const backpressure_sleep_ns = 5 * glib.time.duration.MilliSecond;
        const accept_backlog: usize = 1;
        const max_zero_rx_windows: u8 = 8;

        const gap_service_uuid: u16 = 0x1800;
        const peripheral_preferred_conn_params_uuid: u16 = 0x2A04;
        const preferred_conn_interval_min: u16 = 0x0006;
        const preferred_conn_interval_max: u16 = 0x000C;
        const preferred_conn_latency: u16 = 0;
        const preferred_supervision_timeout: u16 = 0x00C8;

        const gap_chars = [_]bt.Peripheral.CharDef{
            bt.Peripheral.Char(peripheral_preferred_conn_params_uuid, .{ .read = true }),
        };
        const chars = [_]bt.Peripheral.CharDef{
            bt.Peripheral.Char(consts.tx_char_uuid, .{ .notify = true }),
            bt.Peripheral.Char(consts.rx_char_uuid, .{ .write = true, .write_without_response = true }),
        };
        const services = [_]bt.Peripheral.ServiceDef{
            bt.Peripheral.Service(consts.service_uuid, &chars),
            bt.Peripheral.Service(gap_service_uuid, &gap_chars),
        };

        pub fn init(allocator: glib.std.mem.Allocator, host: bt.Host, app: *ZuxAppType, task_options: glib.task.Options) !Self {
            return .{
                .allocator = allocator,
                .host = host,
                .app = app,
                .task_options = task_options,
                .accept_ch = try AcceptChannel.make(allocator, accept_backlog),
            };
        }

        pub fn start(self: *Self) !void {
            self.stop_requested.store(false, .release);
            log.debug("starting server runtime", .{});
            self.task = try grt.task.go(
                "zux/ble_speed/server",
                self.task_options,
                glib.task.Routine.init(self, threadMain),
            );
        }

        pub fn stop(self: *Self) void {
            self.stop_requested.store(true, .release);
            if (self.accept_alive) self.accept_ch.close();
            if (self.task) |task| {
                task.join();
                self.task = null;
            }
            if (self.accept_alive) {
                self.accept_alive = false;
                self.accept_ch.deinit();
            }
        }

        fn threadMain(self: *Self) void {
            self.loop() catch |err| self.publishError(err);
        }

        fn shouldStop(self: *Self) bool {
            return self.stop_requested.load(.acquire);
        }

        fn loop(self: *Self) !void {
            log.debug("server loop starting", .{});
            var peripheral = self.host.peripheral();
            peripheral.addEventHook(self, onPeripheralEvent);
            peripheral.addSubscriptionHook(self, onSubscriptionEvent);
            defer peripheral.removeSubscriptionHook(self, onSubscriptionEvent);
            defer peripheral.removeEventHook(self, onPeripheralEvent);
            defer peripheral.stop();

            peripheral.setConfig(.{ .services = &services });
            peripheral.setRequestHandler(self, onPeripheralRequest);
            try peripheral.start();
            try startSpeedAdvertising(peripheral);
            try self.dispatchPeriphAdvertisingStarted();

            while (!self.shouldStop()) {
                const accepted = self.accept_ch.recv() catch break;
                if (!accepted.ok) break;
                const conn = accepted.value;
                if (conn == 0) {
                    startSpeedAdvertising(peripheral) catch |err| switch (err) {
                        error.AlreadyAdvertising => {},
                        else => log.err("restart advertising failed: {s}", .{@errorName(err)}),
                    };
                    continue;
                }

                try self.runTxLoop(peripheral, conn);
            }
        }

        fn runTxLoop(self: *Self, peripheral: bt.Peripheral, conn: u16) !void {
            self.setConnHandle(conn);
            defer self.clearConn(conn);

            var seq: u32 = 0;
            var tx_bytes: u32 = 0;
            var tx_packets: u32 = 0;
            var rx_window: RxWindow = .{};
            var last_window = grt.time.instant.now();
            var packet_buf: [consts.max_payload_len + consts.Header.encoded_len]u8 = undefined;
            var zero_rx_windows: u8 = 0;

            while (!self.shouldStop() and self.isConnActive(conn)) {
                const packet = makePacket(&packet_buf, seq, self.currentPacketPayloadLen());
                const notify_started = grt.time.instant.now();
                peripheral.notify(conn, consts.tx_char_uuid, packet) catch |err| switch (err) {
                    error.NotSubscribed, error.NotConnected => {
                        log.info("server notify stopped conn={} seq={} err={s}", .{ conn, seq, @errorName(err) });
                        self.clearConn(conn);
                        try self.dispatchStop(conn);
                        grt.time.sleep(reconnect_sleep_ns);
                        return;
                    },
                    error.Busy, error.Timeout, error.Rejected => {
                        log.info("server notify backpressure conn={} seq={} err={s}", .{ conn, seq, @errorName(err) });
                        grt.time.sleep(backpressure_sleep_ns);
                        continue;
                    },
                    else => {
                        log.err("server notify failed conn={} seq={} err={s}", .{ conn, seq, @errorName(err) });
                        try self.dispatchErrorFrom(err);
                        grt.time.sleep(reconnect_sleep_ns);
                        return;
                    },
                };
                const notify_elapsed = grt.time.instant.now() - notify_started;
                if (notify_elapsed > 100 * glib.time.duration.MilliSecond) {
                    log.info("server notify slow conn={} seq={} bytes={} elapsed_ms={}", .{
                        conn,
                        seq,
                        packet.len,
                        @divFloor(notify_elapsed, glib.time.duration.MilliSecond),
                    });
                }
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
                    if (tx_packets > 0 and rx_window.packets == 0) {
                        zero_rx_windows +|= 1;
                        self.logZeroRxWindow(tx_packets, tx_bytes, rx_window, zero_rx_windows);
                        if (zero_rx_windows >= max_zero_rx_windows) {
                            log.warn("server rx idle watchdog disconnect conn={} zero_windows={}", .{ conn, zero_rx_windows });
                            peripheral.disconnect(conn);
                            self.clearConn(conn);
                            try self.dispatchStop(conn);
                            return;
                        }
                    } else {
                        zero_rx_windows = 0;
                    }
                    tx_bytes = 0;
                    tx_packets = 0;
                    rx_window = .{};
                    last_window = now;
                }

                grt.time.sleep(tx_pace_ns);
            }
        }

        fn onPeripheralEvent(ctx: ?*anyopaque, event: bt.Peripheral.Event) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .connected => |info| {
                    log.info("server connected conn={} interval={} latency={}", .{ info.conn_handle, info.interval, info.latency });
                    self.dispatchPeriphConnected(info) catch {};
                },
                .connection_updated => |info| {
                    log.info("server connection updated conn={} interval={} latency={}", .{ info.conn_handle, info.interval, info.latency });
                    self.dispatchPeriphConnectionUpdated(info) catch {};
                },
                .disconnected => |conn_handle| {
                    log.info("server disconnected conn={}", .{conn_handle});
                    self.setMtu(bt.Central.DEFAULT_ATT_MTU);
                    self.clearConn(conn_handle);
                    _ = self.signalAccept(0);
                    self.dispatchStop(conn_handle) catch {};
                    self.dispatchPeriphDisconnected(conn_handle) catch {};
                },
                .mtu_changed => |info| {
                    log.info("server mtu changed conn={} mtu={}", .{ info.conn_handle, info.mtu });
                    self.setMtu(info.mtu);
                    self.dispatchPeriphMtuChanged(info) catch {};
                },
                .advertising_started => self.dispatchPeriphAdvertisingStarted() catch {},
                .advertising_stopped => self.dispatchPeriphAdvertisingStopped() catch {},
            }
        }

        fn onSubscriptionEvent(ctx: ?*anyopaque, info: bt.Peripheral.SubscriptionInfo) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (info.char_uuid != consts.tx_char_uuid) return;
            const subscribed = (info.cccd_value & 0x0001) != 0;
            log.info("server subscription conn={} service=0x{x} char=0x{x} cccd=0x{x} subscribed={}", .{
                info.conn_handle,
                info.service_uuid,
                info.char_uuid,
                info.cccd_value,
                subscribed,
            });
            if (subscribed) {
                self.acceptConn(info.conn_handle);
                self.dispatchReady(info.conn_handle, self.currentConnInterval(), self.currentAttMtu()) catch {};
                self.dispatchStart(info.conn_handle) catch {};
            } else {
                self.clearConn(info.conn_handle);
                self.dispatchStop(info.conn_handle) catch {};
            }
        }

        fn onPeripheralRequest(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (req.char_uuid == peripheral_preferred_conn_params_uuid and req.op == .read) {
                var value: [8]u8 = undefined;
                glib.std.mem.writeInt(u16, value[0..2], preferred_conn_interval_min, .little);
                glib.std.mem.writeInt(u16, value[2..4], preferred_conn_interval_max, .little);
                glib.std.mem.writeInt(u16, value[4..6], preferred_conn_latency, .little);
                glib.std.mem.writeInt(u16, value[6..8], preferred_supervision_timeout, .little);
                rw.write(&value);
                log.info("served peripheral preferred connection params min={} max={} latency={} timeout={}", .{
                    preferred_conn_interval_min,
                    preferred_conn_interval_max,
                    preferred_conn_latency,
                    preferred_supervision_timeout,
                });
                return;
            }
            if (req.char_uuid == consts.rx_char_uuid and req.op != .read) {
                self.noteRxPacket(req.data);
                if (req.op == .write) rw.ok();
                return;
            }
            rw.err(0x06);
        }

        fn setConnHandle(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            if (self.conn_handle != conn_handle) self.resetRxTrackingLocked();
            self.conn_handle = conn_handle;
            self.mutex.unlock();
        }

        fn setMtu(self: *Self, att_mtu: u16) void {
            self.mutex.lock();
            self.att_mtu = att_mtu;
            self.mutex.unlock();
        }

        fn currentAttMtu(self: *Self) u16 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.att_mtu;
        }

        fn currentConnInterval(self: *Self) u16 {
            _ = self;
            return preferred_conn_interval_max;
        }

        fn acceptConn(self: *Self, conn_handle: u16) void {
            if (!self.signalAccept(conn_handle)) {
                log.warn("subscription backlog full; disconnect conn={}", .{conn_handle});
                self.host.peripheral().disconnect(conn_handle);
            }
        }

        fn signalAccept(self: *Self, conn_handle: u16) bool {
            if (!self.accept_alive) return false;
            const result = self.accept_ch.sendTimeout(conn_handle, 0) catch return false;
            return result.ok;
        }

        fn clearConn(self: *Self, conn_handle: u16) void {
            self.mutex.lock();
            if (self.conn_handle == conn_handle) {
                self.conn_handle = 0;
            }
            self.mutex.unlock();
        }

        fn isConnActive(self: *Self, conn_handle: u16) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.conn_handle == conn_handle;
        }

        fn currentPacketPayloadLen(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return packetPayloadLenForAttMtu(self.att_mtu);
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

        fn logZeroRxWindow(self: *Self, tx_packets: u32, tx_bytes: u32, rx: RxWindow, zero_rx_windows: u8) void {
            if (tx_packets == 0 or rx.packets != 0) return;
            const now = grt.time.instant.now();
            if (self.last_zero_rx_log != 0 and now - self.last_zero_rx_log < 5 * glib.time.duration.Second) return;
            self.last_zero_rx_log = now;

            self.mutex.lock();
            const conn_handle = self.conn_handle;
            const subscribed = conn_handle != 0;
            const att_mtu = self.att_mtu;
            self.mutex.unlock();

            log.info("server tx active but rx idle conn={} subscribed={} att_mtu={} tx_packets={} tx_bytes={} expected_rx_seq={} zero_windows={}", .{
                conn_handle,
                subscribed,
                att_mtu,
                tx_packets,
                tx_bytes,
                rx.expected_seq,
                zero_rx_windows,
            });
        }

        fn dispatchPeriphAdvertisingStarted(self: *Self) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_advertising_started = .{ .source_id = source_id } },
            });
        }

        fn dispatchPeriphAdvertisingStopped(self: *Self) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_advertising_stopped = .{ .source_id = source_id } },
            });
        }

        fn dispatchPeriphConnected(self: *Self, info: bt.Peripheral.ConnectionInfo) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_connected = .{
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

        fn dispatchPeriphConnectionUpdated(self: *Self, info: bt.Peripheral.ConnectionInfo) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_connection_updated = .{
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

        fn dispatchPeriphDisconnected(self: *Self, conn_handle: u16) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                } },
            });
        }

        fn dispatchPeriphMtuChanged(self: *Self, info: bt.Peripheral.MtuInfo) !void {
            _ = try self.app.dispatch(.{
                .origin = .source,
                .timestamp = grt.time.instant.now(),
                .body = .{ .ble_periph_mtu_changed = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .mtu = info.mtu,
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
            event.role = .server;
            event.conn_handle = conn_handle;
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchReady(self: *Self, conn_handle: u16, conn_interval: u16, att_mtu: u16) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .ready);
            event.role = .server;
            event.conn_handle = conn_handle;
            event.conn_interval = conn_interval;
            event.att_mtu = att_mtu;
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchStop(self: *Self, conn_handle: u16) !void {
            const event = try speed_test.ActionEvent.init(self.allocator, .stop);
            event.role = .server;
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
            event.role = .server;
            event.error_code = errorCode(err);
            setErrorName(event, @errorName(err));
            try self.dispatchCustom(speed_test.ActionEvent, event);
        }

        fn dispatchErrorFrom(self: *Self, err: anyerror) !void {
            const code = errorCode(err);
            log.err("server fail err={s} code={}", .{ @errorName(err), code });
            try self.dispatchError(err);
        }

        fn publishError(self: *Self, err: anyerror) void {
            self.dispatchErrorFrom(err) catch {};
        }

        fn startSpeedAdvertising(peripheral: bt.Peripheral) bt.Peripheral.AdvError!void {
            try peripheral.startAdvertising(.{
                .device_name = "mbedz-ble-speed-test",
                .service_uuids = &.{consts.service_uuid},
                .connectable = true,
            });
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
