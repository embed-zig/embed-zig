//! host.Central — `bt.Central` implementation backed by the built-in HCI host.
//!
//! Wraps shared `host.Hci` to implement the low-level `bt.Central` VTable.
//! Translates scan / connect / GATT client operations into HCI + ATT traffic.

const std = @import("std");
const bt = @import("../../bt.zig");
const att = @import("att.zig");
const gatt_client = @import("gatt/client.zig");

pub fn Central(comptime lib: type) type {
    return struct {
        const Self = @This();
        const POLL_INTERVAL_NS: u64 = 1_000_000;
        const MIN_WAIT_TIMEOUT_MS: u32 = 1000;
        const CONNECT_TIMEOUT_MS: u32 = 5000;

        hci: bt.Hci,
        state: bt.Central.State = .idle,
        started: bool = false,
        mutex: lib.Thread.Mutex = .{},
        hooks: std.ArrayListUnmanaged(EventHook) = .{},
        scan_service_uuids: std.ArrayListUnmanaged(u16) = .{},
        allocator: lib.mem.Allocator,

        const EventHook = struct {
            ctx: ?*anyopaque,
            cb: *const fn (?*anyopaque, bt.Central.CentralEvent) void,
        };

        const ParsedAdvReport = struct {
            addr: bt.Central.BdAddr,
            addr_type: bt.Central.AddrType,
            data: []const u8,
            rssi: i8,
        };

        const AdvIterator = struct {
            raw: []const u8,
            remaining: usize,
            offset: usize,

            pub fn init(raw: []const u8) AdvIterator {
                return .{
                    .raw = raw,
                    .remaining = if (raw.len > 0) raw[0] else 0,
                    .offset = 1,
                };
            }

            pub fn next(self: *AdvIterator) ?ParsedAdvReport {
                if (self.remaining == 0) return null;
                if (self.offset + 9 > self.raw.len) {
                    self.remaining = 0;
                    return null;
                }

                _ = self.raw[self.offset];
                self.offset += 1;

                const addr_type = switch (self.raw[self.offset]) {
                    0x00, 0x02 => bt.Central.AddrType.public,
                    else => bt.Central.AddrType.random,
                };
                self.offset += 1;

                const addr = self.raw[self.offset..][0..6].*;
                self.offset += 6;

                const data_len: usize = self.raw[self.offset];
                self.offset += 1;
                if (self.offset + data_len + 1 > self.raw.len) {
                    self.remaining = 0;
                    return null;
                }

                const data = self.raw[self.offset .. self.offset + data_len];
                self.offset += data_len;

                const rssi: i8 = @bitCast(self.raw[self.offset]);
                self.offset += 1;

                self.remaining -= 1;
                return .{
                    .addr = addr,
                    .addr_type = addr_type,
                    .data = data,
                    .rssi = rssi,
                };
            }
        };

        pub fn init(hci: bt.Hci, allocator: lib.mem.Allocator) Self {
            return .{ .hci = hci, .allocator = allocator };
        }

        pub fn start(self: *Self) bt.Central.StartError!void {
            if (self.started) return;
            self.hci.retain() catch return error.Unexpected;
            errdefer {
                self.hci.release();
            }
            self.hci.setCentralListener(.{
                .ctx = self,
                .on_adv_report = onAdvReport,
                .on_connected = onConnected,
                .on_disconnected = onDisconnected,
                .on_notification = onNotification,
            });
            errdefer self.hci.setCentralListener(.{});
            self.started = true;
        }

        pub fn stop(self: *Self) void {
            if (!self.started) return;
            if (self.state == .scanning) self.stopScanning();
            self.hci.setCentralListener(.{});
            self.hci.release();
            self.started = false;
            self.state = .idle;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.scan_service_uuids.deinit(self.allocator);
            self.hooks.deinit(self.allocator);
        }

        pub fn startScanning(self: *Self, config: bt.Central.ScanConfig) bt.Central.ScanError!void {
            self.mutex.lock();
            self.scan_service_uuids.clearRetainingCapacity();
            self.scan_service_uuids.appendSlice(self.allocator, config.service_uuids) catch {
                self.mutex.unlock();
                return error.Unexpected;
            };
            self.mutex.unlock();

            self.state = .scanning;
            self.hci.startScanning(.{
                .active = config.active,
                .interval = @max(1, config.interval_ms * 16 / 10),
                .window = @max(1, config.window_ms * 16 / 10),
                .filter_duplicates = config.filter_duplicates,
            }) catch |err| return switch (err) {
                error.Busy => blk: {
                    self.state = .idle;
                    break :blk error.Busy;
                },
                else => blk: {
                    self.state = .idle;
                    break :blk error.Unexpected;
                },
            };
        }

        pub fn stopScanning(self: *Self) void {
            self.mutex.lock();
            self.scan_service_uuids.clearRetainingCapacity();
            self.mutex.unlock();

            self.hci.stopScanning();
            self.state = .idle;
        }

        pub fn connect(self: *Self, addr: bt.Central.BdAddr, addr_type: bt.Central.AddrType, params: bt.Central.ConnParams) bt.Central.ConnectError!bt.Central.ConnectionInfo {
            self.hci.connect(addr, switch (addr_type) {
                .public => .public,
                .random => .random,
            }, .{
                .interval_min = params.interval_min,
                .interval_max = params.interval_max,
                .latency = params.latency,
                .timeout = params.timeout,
            }) catch |err| return switch (err) {
                error.Timeout => error.Timeout,
                error.Busy, error.Rejected => error.Rejected,
                else => error.Unexpected,
            };
            self.state = .connecting;

            var waited_ms: u32 = 0;
            while (self.hci.isConnectingCentral()) : (waited_ms += 1) {
                if (waited_ms >= CONNECT_TIMEOUT_MS) {
                    self.hci.cancelConnect();
                    self.state = .idle;
                    return error.Timeout;
                }
                lib.Thread.sleep(POLL_INTERVAL_NS);
            }
            const link = self.hci.getLink(.central) orelse {
                self.state = .idle;
                return error.Rejected;
            };
            self.state = .connected;
            return linkToConnectionInfo(link);
        }

        pub fn disconnect(self: *Self, conn_handle: u16) void {
            const wait_timeout_ms = if (self.hci.getLinkByHandle(conn_handle)) |link|
                @max(MIN_WAIT_TIMEOUT_MS, @as(u32, link.timeout) * 10)
            else
                MIN_WAIT_TIMEOUT_MS;
            self.hci.disconnect(conn_handle, 0x13);
            var waited_ms: u32 = 0;
            while (self.hci.getLinkByHandle(conn_handle) != null and waited_ms < wait_timeout_ms) : (waited_ms += 1) {
                lib.Thread.sleep(POLL_INTERVAL_NS);
            }
            if (self.hci.getLinkByHandle(conn_handle) == null) {
                self.state = .idle;
            }
        }

        pub fn discoverServices(self: *Self, conn_handle: u16, out: []bt.Central.DiscoveredService) bt.Central.GattError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeDiscoverServices(&req_buf, 0x0001);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.READ_BY_GROUP_TYPE_REQUEST)) |_| return error.AttError;

            var tmp: [16]gatt_client.DiscoveredService = undefined;
            const count = gatt_client.parseDiscoverServicesResponse(resp, &tmp);
            const n = @min(count, out.len);
            for (0..n) |i| {
                out[i] = .{
                    .start_handle = tmp[i].start_handle,
                    .end_handle = tmp[i].end_handle,
                    .uuid = tmp[i].uuid,
                };
            }
            return n;
        }

        pub fn discoverChars(self: *Self, conn_handle: u16, start_handle: u16, end_handle: u16, out: []bt.Central.DiscoveredChar) bt.Central.GattError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeDiscoverChars(&req_buf, start_handle, end_handle);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.READ_BY_TYPE_REQUEST)) |_| return error.AttError;

            var tmp: [16]gatt_client.DiscoveredChar = undefined;
            const count = gatt_client.parseDiscoverCharsResponse(resp, &tmp);
            const n = @min(count, out.len);
            for (0..n) |i| {
                out[i] = .{
                    .decl_handle = tmp[i].decl_handle,
                    .value_handle = tmp[i].value_handle,
                    .cccd_handle = 0,
                    .properties = tmp[i].properties,
                    .uuid = tmp[i].uuid,
                };
            }

            for (0..n) |i| {
                if (out[i].properties & 0x30 != 0) {
                    const cccd_start = out[i].value_handle + 1;
                    const cccd_end = if (i + 1 < n) out[i + 1].decl_handle - 1 else end_handle;
                    if (cccd_start <= cccd_end) {
                        const find_req = gatt_client.encodeFindCccd(&req_buf, cccd_start, cccd_end);
                        const find_resp = self.sendAttRequest(conn_handle, find_req, &resp_buf) catch continue;
                        if (gatt_client.parseFindCccdResponse(find_resp)) |cccd_handle| {
                            out[i].cccd_handle = cccd_handle;
                        }
                    }
                }
            }

            return n;
        }

        pub fn gattRead(self: *Self, conn_handle: u16, attr_handle: u16, out: []u8) bt.Central.GattError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeRead(&req_buf, attr_handle);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.READ_REQUEST)) |_| return error.AttError;
            return gatt_client.parseReadResponse(resp, out);
        }

        pub fn gattWrite(self: *Self, conn_handle: u16, attr_handle: u16, data: []const u8) bt.Central.GattError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeWrite(&req_buf, attr_handle, data);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn gattWriteNoResp(self: *Self, conn_handle: u16, attr_handle: u16, data: []const u8) bt.Central.GattError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeWriteCommand(&req_buf, attr_handle, data);
            self.hci.sendAcl(conn_handle, req) catch |err| return switch (err) {
                error.Timeout => error.Timeout,
                error.Disconnected => error.Disconnected,
                else => error.Unexpected,
            };
        }

        pub fn subscribe(self: *Self, conn_handle: u16, cccd_handle: u16) bt.Central.GattError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeSubscribe(&req_buf, cccd_handle);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn subscribeIndications(self: *Self, conn_handle: u16, cccd_handle: u16) bt.Central.GattError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeSubscribeIndications(&req_buf, cccd_handle);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn unsubscribe(self: *Self, conn_handle: u16, cccd_handle: u16) bt.Central.GattError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeUnsubscribe(&req_buf, cccd_handle);
            const resp = try self.sendAttRequest(conn_handle, req, &resp_buf);

            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn getState(self: *Self) bt.Central.State {
            return self.state;
        }

        pub fn getAddr(self: *Self) ?bt.Central.BdAddr {
            return self.hci.getAddr();
        }

        pub fn addEventHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, bt.Central.CentralEvent) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch return;
        }

        pub fn removeEventHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, bt.Central.CentralEvent) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.hooks.items.len) {
                const hook = self.hooks.items[i];
                if (hook.ctx == ctx and hook.cb == cb) {
                    _ = self.hooks.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        pub fn resolveChar(self: *Self, conn_handle: u16, svc_uuid: u16, char_uuid: u16) bt.Central.GattError!bt.Central.DiscoveredChar {
            var services: [16]bt.Central.DiscoveredService = undefined;
            const svc_count = try self.discoverServices(conn_handle, &services);
            var service: ?bt.Central.DiscoveredService = null;
            for (services[0..svc_count]) |svc| {
                if (svc.uuid == svc_uuid) {
                    service = svc;
                    break;
                }
            }
            const found_service = service orelse return error.AttError;

            var chars: [16]bt.Central.DiscoveredChar = undefined;
            const char_count = try self.discoverChars(conn_handle, found_service.start_handle, found_service.end_handle, &chars);
            for (chars[0..char_count]) |ch| {
                if (ch.uuid == char_uuid) return ch;
            }
            return error.AttError;
        }

        fn sendAttRequest(self: *Self, conn_handle: u16, req: []const u8, out: []u8) bt.Central.GattError![]const u8 {
            const n = self.hci.sendAttRequest(conn_handle, req, out) catch |err| return switch (err) {
                error.Timeout => error.Timeout,
                error.Disconnected => error.Disconnected,
                else => error.Unexpected,
            };
            return out[0..n];
        }

        fn linkToConnectionInfo(link: bt.Hci.Link) bt.Central.ConnectionInfo {
            return .{
                .conn_handle = link.conn_handle,
                .peer_addr = link.peer_addr,
                .peer_addr_type = switch (link.peer_addr_type) {
                    .public => .public,
                    .random => .random,
                },
                .interval = link.interval,
                .latency = link.latency,
                .timeout = link.timeout,
            };
        }

        fn fireEvent(self: *Self, event: bt.Central.CentralEvent) void {
            self.mutex.lock();
            const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
                self.mutex.unlock();
                return;
            };
            self.mutex.unlock();
            defer self.allocator.free(snapshot);
            for (snapshot) |hook| hook.cb(hook.ctx, event);
        }

        fn onAdvReport(ctx: ?*anyopaque, data: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.state != .scanning) return;

            var iter = AdvIterator.init(data);
            while (iter.next()) |report| {
                self.mutex.lock();
                const matches = matchesServiceFilter(report.data, self.scan_service_uuids.items);
                self.mutex.unlock();
                if (!matches) continue;

                var adv: bt.Central.AdvReport = .{
                    .addr = report.addr,
                    .addr_type = report.addr_type,
                    .rssi = report.rssi,
                };
                fillAdvReport(&adv, report);
                self.fireEvent(.{ .device_found = adv });
            }
        }

        fn fillAdvReport(out: *bt.Central.AdvReport, report: ParsedAdvReport) void {
            const data_len = @min(report.data.len, out.data.len);
            @memcpy(out.data[0..data_len], report.data[0..data_len]);
            out.data_len = @intCast(data_len);

            var offset: usize = 0;
            while (offset < report.data.len) {
                const field_len: usize = report.data[offset];
                if (field_len == 0) break;
                const next = offset + 1 + field_len;
                if (next > report.data.len or field_len < 1) break;

                const field_type = report.data[offset + 1];
                const field_data = report.data[offset + 2 .. next];
                if (field_type == 0x09 or field_type == 0x08) {
                    const name_len = @min(field_data.len, out.name.len);
                    @memcpy(out.name[0..name_len], field_data[0..name_len]);
                    out.name_len = @intCast(name_len);
                    if (field_type == 0x09) break;
                }

                offset = next;
            }
        }

        fn matchesServiceFilter(data: []const u8, filter: []const u16) bool {
            if (filter.len == 0) return true;

            var offset: usize = 0;
            while (offset < data.len) {
                const field_len: usize = data[offset];
                if (field_len == 0) break;
                const next = offset + 1 + field_len;
                if (next > data.len or field_len < 1) break;

                const field_type = data[offset + 1];
                const field_data = data[offset + 2 .. next];
                switch (field_type) {
                    0x02, 0x03 => {
                        var pos: usize = 0;
                        while (pos + 2 <= field_data.len) : (pos += 2) {
                            const uuid = std.mem.readInt(u16, field_data[pos..][0..2], .little);
                            for (filter) |wanted| {
                                if (wanted == uuid) return true;
                            }
                        }
                    },
                    0x16 => {
                        if (field_data.len >= 2) {
                            const uuid = std.mem.readInt(u16, field_data[0..][0..2], .little);
                            for (filter) |wanted| {
                                if (wanted == uuid) return true;
                            }
                        }
                    },
                    else => {},
                }

                offset = next;
            }

            return false;
        }

        fn onConnected(ctx: ?*anyopaque, link: bt.Hci.Link) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.state = .connected;
            self.fireEvent(.{ .connected = linkToConnectionInfo(link) });
        }

        fn onDisconnected(ctx: ?*anyopaque, conn_handle: u16, _: u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.state = .idle;
            self.fireEvent(.{ .disconnected = conn_handle });
        }

        fn onNotification(ctx: ?*anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            var notif = bt.Central.NotificationData{
                .conn_handle = conn_handle,
                .attr_handle = attr_handle,
            };
            const n = @min(data.len, notif.data.len);
            @memcpy(notif.data[0..n], data[0..n]);
            notif.len = @truncate(n);
            self.fireEvent(.{ .notification = notif });
        }
    };
}

test "bt/unit_tests/host/Central_advertising_iterator_parses_one_report" {
    const Impl = Central(std);
    const raw = [_]u8{
        1,
        0x00,
        0x00,
        0xA1,
        0xA2,
        0xA3,
        0xA4,
        0xA5,
        0xA6,
        12,
        0x02,
        0x01,
        0x06,
        0x03,
        0x03,
        0x0D,
        0x18,
        0x04,
        0x09,
        'Z',
        'i',
        'g',
        0xC5,
    };

    var iter = Impl.AdvIterator.init(&raw);
    const report = iter.next() orelse return error.NoReport;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 }, &report.addr);
    try std.testing.expectEqual(bt.Central.AddrType.public, report.addr_type);
    try std.testing.expectEqual(@as(i8, -59), report.rssi);
    try std.testing.expect(iter.next() == null);

    var adv: bt.Central.AdvReport = .{
        .addr = report.addr,
        .addr_type = report.addr_type,
        .rssi = report.rssi,
    };
    Impl.fillAdvReport(&adv, report);
    try std.testing.expectEqualSlices(u8, "Zig", adv.getName());
    try std.testing.expectEqual(@as(u8, 12), adv.data_len);
}

test "bt/unit_tests/host/Central_advertising_filter_matches_uuid16_and_service_data" {
    const Impl = Central(std);

    const uuid_list = [_]u8{
        0x03, 0x03, 0x0D, 0x18,
        0x02, 0x01, 0x06,
    };
    try std.testing.expect(Impl.matchesServiceFilter(&uuid_list, &.{0x180D}));
    try std.testing.expect(!Impl.matchesServiceFilter(&uuid_list, &.{0x180F}));

    const service_data = [_]u8{
        0x05, 0x16, 0x0F, 0x18, 0x01, 0x02,
    };
    try std.testing.expect(Impl.matchesServiceFilter(&service_data, &.{0x180F}));
    try std.testing.expect(!Impl.matchesServiceFilter(&service_data, &.{0x180D}));
}

test "bt/unit_tests/host/Central_advertising_iterator_maps_public_identity_address_to_public" {
    const Impl = Central(std);
    const raw = [_]u8{
        1,
        0x00,
        0x02,
        0xA1,
        0xA2,
        0xA3,
        0xA4,
        0xA5,
        0xA6,
        0,
        0xC5,
    };

    var iter = Impl.AdvIterator.init(&raw);
    const report = iter.next() orelse return error.NoReport;
    try std.testing.expectEqual(bt.Central.AddrType.public, report.addr_type);
}

test "bt/unit_tests/host/Central_connect_resets_state_after_rejected_link" {
    const Impl = Central(std);

    const FakeHci = struct {
        connecting: bool = false,

        pub fn retain(_: *@This()) bt.Hci.Error!void {}
        pub fn release(_: *@This()) void {}
        pub fn setCentralListener(_: *@This(), _: bt.Hci.CentralListener) void {}
        pub fn setPeripheralListener(_: *@This(), _: bt.Hci.PeripheralListener) void {}
        pub fn startScanning(_: *@This(), _: bt.Hci.ScanConfig) bt.Hci.Error!void {}
        pub fn stopScanning(_: *@This()) void {}
        pub fn startAdvertising(_: *@This(), _: bt.Hci.AdvConfig) bt.Hci.Error!void {}
        pub fn stopAdvertising(_: *@This()) void {}
        pub fn connect(self: *@This(), _: bt.Hci.BdAddr, _: bt.Hci.AddrType, _: bt.Hci.ConnConfig) bt.Hci.Error!void {
            self.connecting = false;
        }
        pub fn cancelConnect(_: *@This()) void {}
        pub fn disconnect(_: *@This(), _: u16, _: u8) void {}
        pub fn sendAcl(_: *@This(), _: u16, _: []const u8) bt.Hci.Error!void {}
        pub fn sendAttRequest(_: *@This(), _: u16, _: []const u8, _: []u8) bt.Hci.Error!usize {
            return error.Unexpected;
        }
        pub fn getAddr(_: *@This()) ?bt.Hci.BdAddr {
            return null;
        }
        pub fn getLink(_: *@This(), _: bt.Hci.Role) ?bt.Hci.Link {
            return null;
        }
        pub fn getLinkByHandle(_: *@This(), _: u16) ?bt.Hci.Link {
            return null;
        }
        pub fn isScanning(_: *@This()) bool {
            return false;
        }
        pub fn isAdvertising(_: *@This()) bool {
            return false;
        }
        pub fn isConnectingCentral(self: *@This()) bool {
            return self.connecting;
        }
        pub fn deinit(_: *@This()) void {}
    };

    var fake_hci = FakeHci{};
    var central = Impl.init(bt.Hci.wrap(&fake_hci), std.testing.allocator);
    defer central.deinit();

    try std.testing.expectError(error.Rejected, central.connect(.{ 1, 2, 3, 4, 5, 6 }, .public, .{}));
    try std.testing.expectEqual(bt.Central.State.idle, central.getState());
}
