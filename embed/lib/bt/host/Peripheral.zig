//! host.Peripheral — `bt.Peripheral` implementation backed by the built-in HCI host.
//!
//! Wraps shared `host.Hci` to implement the low-level `bt.Peripheral`
//! VTable, including advertising and ATT server request handling.

const glib = @import("glib");

const root = @import("../../bt.zig");
const bt = @import("../Peripheral.zig");
const att = @import("att.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();

        hci: root.Hci,
        state: bt.State = .idle,
        started: bool = false,
        mutex: grt.std.Thread.Mutex = .{},
        allocator: glib.std.mem.Allocator,
        hooks: glib.std.ArrayListUnmanaged(EventHook) = .{},
        subscription_hooks: glib.std.ArrayListUnmanaged(SubscriptionHook) = .{},
        services: glib.std.ArrayListUnmanaged(ServiceEntry) = .{},
        chars: glib.std.ArrayListUnmanaged(CharEntry) = .{},
        request_ctx: ?*anyopaque = null,
        request_handler: ?bt.RequestHandlerFn = null,
        conn_handle: u16 = 0,
        mtu: u16 = att.DEFAULT_MTU,

        const EventHook = struct {
            ctx: ?*anyopaque,
            cb: *const fn (?*anyopaque, bt.Event) void,
        };

        pub const SubscriptionInfo = bt.SubscriptionInfo;

        const SubscriptionHook = struct {
            ctx: ?*anyopaque,
            cb: *const fn (?*anyopaque, SubscriptionInfo) void,
        };

        const ServiceEntry = struct {
            uuid: u16,
            start_handle: u16,
            end_handle: u16,
        };

        const CharEntry = struct {
            svc_uuid: u16,
            char_uuid: u16,
            config: bt.CharConfig,
            decl_handle: u16 = 0,
            value_handle: u16 = 0,
            cccd_handle: u16 = 0,
            cccd_value: u16 = 0,
        };

        const ResponseState = struct {
            len: usize = 0,
            ok: bool = false,
            err_code: ?att.ErrorCode = null,
            data: [att.MAX_PDU_LEN]u8 = undefined,

            fn writeFn(ptr: *anyopaque, data: []const u8) void {
                const self: *ResponseState = @ptrCast(@alignCast(ptr));
                const n = @min(data.len, self.data.len - self.len);
                if (n == 0) return;
                @memcpy(self.data[self.len .. self.len + n], data[0..n]);
                self.len += n;
            }

            fn okFn(ptr: *anyopaque) void {
                const self: *ResponseState = @ptrCast(@alignCast(ptr));
                self.ok = true;
            }

            fn errFn(ptr: *anyopaque, code: u8) void {
                const self: *ResponseState = @ptrCast(@alignCast(ptr));
                self.err_code = @enumFromInt(code);
            }
        };

        pub fn init(hci: root.Hci, allocator: glib.std.mem.Allocator) Self {
            return .{ .hci = hci, .allocator = allocator };
        }

        pub fn start(self: *Self) bt.StartError!void {
            if (self.started) return;
            self.hci.retain() catch return error.Unexpected;
            errdefer {
                self.hci.release();
            }
            self.hci.setPeripheralListener(.{
                .ctx = self,
                .on_connected = onConnected,
                .on_disconnected = onDisconnected,
                .on_att_request = onAttRequest,
            });
            errdefer self.hci.setPeripheralListener(.{});
            self.started = true;
        }

        pub fn stop(self: *Self) void {
            if (!self.started) return;
            if (self.state == .advertising) self.stopAdvertising();
            self.hci.setPeripheralListener(.{});
            self.hci.release();
            self.started = false;
            self.state = .idle;
            self.conn_handle = 0;
            self.mtu = att.DEFAULT_MTU;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.hooks.deinit(self.allocator);
            self.subscription_hooks.deinit(self.allocator);
            self.services.deinit(self.allocator);
            self.chars.deinit(self.allocator);
        }

        pub fn setConfig(self: *Self, config: bt.GattConfig) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.services.clearRetainingCapacity();
            self.chars.clearRetainingCapacity();

            for (config.services) |svc| {
                for (svc.chars) |ch| {
                    self.chars.append(self.allocator, .{
                        .svc_uuid = svc.uuid,
                        .char_uuid = ch.uuid,
                        .config = ch.config,
                    }) catch @panic("OOM rebuilding peripheral GATT chars");
                }
            }
            self.rebuildAttributeLayoutLocked();
        }

        pub fn setRequestHandler(self: *Self, ctx: ?*anyopaque, func: bt.RequestHandlerFn) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.request_ctx = ctx;
            self.request_handler = func;
        }

        pub fn clearRequestHandler(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.request_ctx = null;
            self.request_handler = null;
        }

        pub fn startAdvertising(self: *Self, config: bt.AdvConfig) bt.AdvError!void {
            if (self.state == .advertising) return error.AlreadyAdvertising;

            var adv_data_buf: [31]u8 = undefined;
            var adv_pos: usize = 0;

            if (adv_pos + 3 <= 31) {
                adv_data_buf[adv_pos] = 0x02;
                adv_data_buf[adv_pos + 1] = 0x01;
                adv_data_buf[adv_pos + 2] = 0x06;
                adv_pos += 3;
            }

            if (config.device_name.len > 0) {
                const name_len = @min(config.device_name.len, 31 - adv_pos - 2);
                if (name_len > 0) {
                    adv_data_buf[adv_pos] = @truncate(name_len + 1);
                    adv_data_buf[adv_pos + 1] = 0x09;
                    @memcpy(adv_data_buf[adv_pos + 2 ..][0..name_len], config.device_name[0..name_len]);
                    adv_pos += 2 + name_len;
                }
            }

            if (config.service_uuids.len > 0) {
                if (adv_pos + 2 <= adv_data_buf.len) {
                    const max_uuids = (adv_data_buf.len - adv_pos - 2) / 2;
                    const uuid_count = @min(config.service_uuids.len, max_uuids);
                    if (uuid_count > 0) {
                        adv_data_buf[adv_pos] = @truncate(uuid_count * 2 + 1);
                        adv_data_buf[adv_pos + 1] = 0x03;
                        adv_pos += 2;
                        for (0..uuid_count) |i| {
                            glib.std.mem.writeInt(u16, adv_data_buf[adv_pos..][0..2], config.service_uuids[i], .little);
                            adv_pos += 2;
                        }
                    }
                }
            }

            self.hci.startAdvertising(.{
                .interval_min = config.interval_min,
                .interval_max = config.interval_max,
                .connectable = config.connectable,
                .adv_data = adv_data_buf[0..adv_pos],
                .scan_rsp_data = config.scan_rsp_data,
            }) catch return error.Unexpected;
            self.state = .advertising;
            self.fireEvent(.{ .advertising_started = {} });
        }

        pub fn stopAdvertising(self: *Self) void {
            if (self.state != .advertising) return;
            self.hci.stopAdvertising();
            self.state = .idle;
            self.fireEvent(.{ .advertising_stopped = {} });
        }

        pub fn notify(self: *Self, conn_handle: u16, char_uuid: u16, data: []const u8) bt.GattError!void {
            if (self.state != .connected or conn_handle != self.conn_handle) return error.NotConnected;
            const entry = self.findCharEntryByCharUuid(char_uuid) orelse return error.InvalidHandle;
            if (!entry.config.notify) return error.InvalidHandle;
            if ((entry.cccd_value & 0x0001) == 0) return error.NotSubscribed;
            var buf: [att.MAX_PDU_LEN]u8 = undefined;
            const pdu = att.encodeNotification(&buf, entry.value_handle, data);
            self.hci.sendAcl(conn_handle, pdu) catch |err| return switch (err) {
                error.Disconnected => error.NotConnected,
                else => error.Unexpected,
            };
        }

        pub fn indicate(self: *Self, conn_handle: u16, char_uuid: u16, data: []const u8) bt.GattError!void {
            if (self.state != .connected or conn_handle != self.conn_handle) return error.NotConnected;
            const entry = self.findCharEntryByCharUuid(char_uuid) orelse return error.InvalidHandle;
            if (!entry.config.indicate) return error.InvalidHandle;
            if ((entry.cccd_value & 0x0002) == 0) return error.NotSubscribed;
            var buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const pdu = att.encodeIndication(&buf, entry.value_handle, data);
            _ = self.hci.sendAttRequest(conn_handle, pdu, &resp_buf) catch |err| return switch (err) {
                error.Disconnected => error.NotConnected,
                else => error.Unexpected,
            };
        }

        pub fn disconnect(self: *Self, conn_handle: u16) void {
            if (self.state != .connected or conn_handle != self.conn_handle) return;
            self.hci.disconnect(conn_handle, 0x13);
        }

        pub fn getState(self: *Self) bt.State {
            return self.state;
        }

        pub fn getAddr(self: *Self) ?bt.BdAddr {
            return self.hci.getAddr();
        }

        pub fn addEventHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, bt.Event) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch @panic("bt.host.Peripheral.addEventHook OOM");
        }

        pub fn removeEventHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, bt.Event) void) void {
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

        pub fn addSubscriptionHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, SubscriptionInfo) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.subscription_hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch @panic("bt.host.Peripheral.addSubscriptionHook OOM");
        }

        pub fn removeSubscriptionHook(self: *Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, SubscriptionInfo) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.subscription_hooks.items.len) {
                const hook = self.subscription_hooks.items[i];
                if (hook.ctx == ctx and hook.cb == cb) {
                    _ = self.subscription_hooks.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        fn findCharHandle(self: *Self, char_uuid: u16) ?u16 {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.chars.items) |entry| {
                if (entry.char_uuid == char_uuid) return entry.value_handle;
            }
            return null;
        }

        fn findCharEntryByCharUuid(self: *Self, char_uuid: u16) ?CharEntry {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.chars.items) |entry| {
                if (entry.char_uuid == char_uuid) return entry;
            }
            return null;
        }

        fn rebuildAttributeLayoutLocked(self: *Self) void {
            self.services.clearRetainingCapacity();
            for (self.chars.items) |*entry| {
                entry.decl_handle = 0;
                entry.value_handle = 0;
                entry.cccd_handle = 0;
            }

            var next_handle: u16 = 1;
            for (self.chars.items, 0..) |entry, i| {
                if (!isFirstServiceOccurrence(self.chars.items, i, entry.svc_uuid)) continue;

                const start_handle = next_handle;
                next_handle += 1;

                for (self.chars.items) |*service_entry| {
                    if (service_entry.svc_uuid != entry.svc_uuid) continue;
                    service_entry.decl_handle = next_handle;
                    next_handle += 1;
                    service_entry.value_handle = next_handle;
                    next_handle += 1;
                    if (service_entry.config.hasCccd()) {
                        service_entry.cccd_handle = next_handle;
                        next_handle += 1;
                    }
                }

                self.services.append(self.allocator, .{
                    .uuid = entry.svc_uuid,
                    .start_handle = start_handle,
                    .end_handle = next_handle - 1,
                }) catch @panic("OOM rebuilding peripheral GATT services");
            }
        }

        fn isFirstServiceOccurrence(entries: []const CharEntry, index: usize, svc_uuid: u16) bool {
            for (entries[0..index]) |entry| {
                if (entry.svc_uuid == svc_uuid) return false;
            }
            return true;
        }

        fn fireEvent(self: *Self, event: bt.Event) void {
            self.mutex.lock();
            const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
                self.mutex.unlock();
                return;
            };
            self.mutex.unlock();
            defer self.allocator.free(snapshot);
            for (snapshot) |hook| hook.cb(hook.ctx, event);
        }

        fn fireSubscriptionEvent(self: *Self, info: SubscriptionInfo) void {
            self.mutex.lock();
            const snapshot = self.allocator.dupe(SubscriptionHook, self.subscription_hooks.items) catch {
                self.mutex.unlock();
                return;
            };
            self.mutex.unlock();
            defer self.allocator.free(snapshot);
            for (snapshot) |hook| hook.cb(hook.ctx, info);
        }

        fn linkToConnectionInfo(link: root.Hci.Link) bt.ConnectionInfo {
            return .{
                .conn_handle = link.conn_handle,
                .peer_addr = link.peer_addr,
                .peer_addr_type = switch (link.peer_addr_type) {
                    .public => .public,
                    .random => .random,
                },
                .interval = link.interval,
                .latency = link.latency,
                .supervision_timeout = link.supervision_timeout,
            };
        }

        fn onConnected(ctx: ?*anyopaque, link: root.Hci.Link) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            self.state = .connected;
            self.conn_handle = link.conn_handle;
            self.mtu = att.DEFAULT_MTU;
            self.mutex.unlock();
            self.fireEvent(.{ .connected = linkToConnectionInfo(link) });
        }

        fn onDisconnected(ctx: ?*anyopaque, conn_handle: u16, _: u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            if (conn_handle != self.conn_handle) {
                self.mutex.unlock();
                return;
            }
            self.state = .idle;
            self.conn_handle = 0;
            self.mtu = att.DEFAULT_MTU;
            for (self.chars.items) |*entry| {
                entry.cccd_value = 0;
            }
            self.mutex.unlock();
            self.fireEvent(.{ .disconnected = conn_handle });
        }

        fn onAttRequest(ctx: ?*anyopaque, conn_handle: u16, data: []const u8, out: []u8) usize {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            return self.handleAttRequest(conn_handle, data, out);
        }

        fn handleAttRequest(self: *Self, conn_handle: u16, data: []const u8, out: []u8) usize {
            const pdu = att.decodePdu(data) orelse return att.encodeErrorResponse(out, 0x00, 0x0000, .invalid_pdu).len;
            return switch (pdu) {
                .exchange_mtu_request => |req| blk: {
                    const mtu = @max(att.DEFAULT_MTU, @min(req.client_mtu, att.MAX_MTU));
                    self.mutex.lock();
                    self.mtu = mtu;
                    self.mutex.unlock();
                    self.fireEvent(.{ .mtu_changed = .{ .conn_handle = conn_handle, .mtu = mtu } });
                    break :blk att.encodeMtuResponse(out, mtu).len;
                },
                .read_by_group_type_request => |req| self.handleReadByGroupType(req, out),
                .read_by_type_request => |req| self.handleReadByType(req, out),
                .find_information_request => |req| self.handleFindInformation(req, out),
                .read_request => |req| self.handleRead(conn_handle, req.handle, out),
                .read_blob_request => |req| att.encodeErrorResponse(out, att.READ_BLOB_REQUEST, req.handle, .attribute_not_long).len,
                .write_request => |req| self.handleWrite(conn_handle, .write, req.handle, req.value, out, true),
                .write_command => |req| self.handleWrite(conn_handle, .write_without_response, req.handle, req.value, out, false),
                else => att.encodeErrorResponse(out, data[0], attRequestHandle(data), .request_not_supported).len,
            };
        }

        fn handleReadByGroupType(self: *Self, req: att.ReadByGroupTypeRequest, out: []u8) usize {
            if (req.uuid != .uuid16 or req.uuid.uuid16 != att.PRIMARY_SERVICE_UUID) {
                return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .unsupported_group_type).len;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            var pos: usize = 2;
            for (self.services.items) |service| {
                if (service.start_handle < req.start_handle or service.start_handle > req.end_handle) continue;
                if (pos + 6 > out.len) break;
                glib.std.mem.writeInt(u16, out[pos..][0..2], service.start_handle, .little);
                glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], service.end_handle, .little);
                glib.std.mem.writeInt(u16, out[pos + 4 ..][0..2], service.uuid, .little);
                pos += 6;
            }

            if (pos == 2) {
                return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.READ_BY_GROUP_TYPE_RESPONSE;
            out[1] = 6;
            return pos;
        }

        fn handleReadByType(self: *Self, req: att.ReadByTypeRequest, out: []u8) usize {
            if (req.uuid != .uuid16 or req.uuid.uuid16 != att.CHARACTERISTIC_UUID) {
                return att.encodeErrorResponse(out, att.READ_BY_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            var pos: usize = 2;
            var handle_num: u32 = req.start_handle;
            while (handle_num <= req.end_handle) : (handle_num += 1) {
                const attr_handle: u16 = @intCast(handle_num);
                if (self.findCharByDeclHandleLocked(attr_handle)) |entry| {
                    if (pos + 7 > out.len) break;
                    glib.std.mem.writeInt(u16, out[pos..][0..2], entry.decl_handle, .little);
                    out[pos + 2] = entry.config.properties();
                    glib.std.mem.writeInt(u16, out[pos + 3 ..][0..2], entry.value_handle, .little);
                    glib.std.mem.writeInt(u16, out[pos + 5 ..][0..2], entry.char_uuid, .little);
                    pos += 7;
                }
            }

            if (pos == 2) {
                return att.encodeErrorResponse(out, att.READ_BY_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.READ_BY_TYPE_RESPONSE;
            out[1] = 7;
            return pos;
        }

        fn handleFindInformation(self: *Self, req: att.FindInformationRequest, out: []u8) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var pos: usize = 2;
            var handle_num: u32 = req.start_handle;
            while (handle_num <= req.end_handle) : (handle_num += 1) {
                const attr_handle: u16 = @intCast(handle_num);
                if (pos + 4 > out.len) break;

                if (self.findServiceByStartHandleLocked(attr_handle) != null) {
                    glib.std.mem.writeInt(u16, out[pos..][0..2], attr_handle, .little);
                    glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.PRIMARY_SERVICE_UUID, .little);
                    pos += 4;
                    continue;
                }
                if (self.findCharByDeclHandleLocked(attr_handle) != null) {
                    glib.std.mem.writeInt(u16, out[pos..][0..2], attr_handle, .little);
                    glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.CHARACTERISTIC_UUID, .little);
                    pos += 4;
                    continue;
                }
                if (self.findCharByValueHandleLocked(attr_handle)) |entry| {
                    glib.std.mem.writeInt(u16, out[pos..][0..2], attr_handle, .little);
                    glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], entry.char_uuid, .little);
                    pos += 4;
                    continue;
                }
                if (self.findCharByCccdHandleLocked(attr_handle) != null) {
                    glib.std.mem.writeInt(u16, out[pos..][0..2], attr_handle, .little);
                    glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.CCCD_UUID, .little);
                    pos += 4;
                }
            }

            if (pos == 2) {
                return att.encodeErrorResponse(out, att.FIND_INFORMATION_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.FIND_INFORMATION_RESPONSE;
            out[1] = 0x01;
            return pos;
        }

        fn handleRead(self: *Self, conn_handle: u16, attr_handle: u16, out: []u8) usize {
            self.mutex.lock();

            for (self.services.items) |service| {
                if (service.start_handle == attr_handle) {
                    out[0] = att.READ_RESPONSE;
                    glib.std.mem.writeInt(u16, out[1..][0..2], service.uuid, .little);
                    self.mutex.unlock();
                    return 3;
                }
            }

            for (self.chars.items) |entry| {
                if (entry.decl_handle == attr_handle) {
                    out[0] = att.READ_RESPONSE;
                    out[1] = entry.config.properties();
                    glib.std.mem.writeInt(u16, out[2..][0..2], entry.value_handle, .little);
                    glib.std.mem.writeInt(u16, out[4..][0..2], entry.char_uuid, .little);
                    self.mutex.unlock();
                    return 6;
                }
                if (entry.value_handle == attr_handle) {
                    const snapshot = entry;
                    const request_ctx = self.request_ctx;
                    const request_handler = self.request_handler;
                    self.mutex.unlock();
                    if (!snapshot.config.read) {
                        return att.encodeErrorResponse(out, att.READ_REQUEST, attr_handle, .read_not_permitted).len;
                    }
                    const handler = request_handler orelse {
                        return att.encodeErrorResponse(out, att.READ_REQUEST, attr_handle, .request_not_supported).len;
                    };
                    return self.dispatchHandler(conn_handle, snapshot, request_ctx, handler, .read, &.{}, out, true);
                }
                if (entry.cccd_handle == attr_handle) {
                    out[0] = att.READ_RESPONSE;
                    glib.std.mem.writeInt(u16, out[1..][0..2], entry.cccd_value, .little);
                    self.mutex.unlock();
                    return 3;
                }
            }

            self.mutex.unlock();
            return att.encodeErrorResponse(out, att.READ_REQUEST, attr_handle, .invalid_handle).len;
        }

        fn handleWrite(self: *Self, conn_handle: u16, op: bt.Operation, attr_handle: u16, value: []const u8, out: []u8, needs_response: bool) usize {
            self.mutex.lock();
            for (self.chars.items) |*entry| {
                if (entry.value_handle == attr_handle) {
                    const snapshot = entry.*;
                    const request_ctx = self.request_ctx;
                    const request_handler = self.request_handler;
                    self.mutex.unlock();
                    switch (op) {
                        .write => {
                            if (!snapshot.config.write) {
                                if (needs_response) {
                                    return att.encodeErrorResponse(out, att.WRITE_REQUEST, attr_handle, .write_not_permitted).len;
                                }
                                return 0;
                            }
                        },
                        .write_without_response => {
                            if (!snapshot.config.write_without_response) return 0;
                        },
                        .read => unreachable,
                    }
                    const handler = request_handler orelse {
                        if (needs_response) {
                            return att.encodeErrorResponse(out, att.WRITE_REQUEST, attr_handle, .request_not_supported).len;
                        }
                        return 0;
                    };
                    return self.dispatchHandler(conn_handle, snapshot, request_ctx, handler, op, value, out, needs_response);
                }
                if (entry.cccd_handle == attr_handle) {
                    var subscription_info: ?SubscriptionInfo = null;
                    if (value.len < 2) {
                        self.mutex.unlock();
                        if (needs_response) {
                            return att.encodeErrorResponse(out, att.WRITE_REQUEST, attr_handle, .invalid_attribute_value_length).len;
                        }
                        return 0;
                    }
                    if (value.len >= 2) {
                        const next_cccd_value = glib.std.mem.readInt(u16, value[0..][0..2], .little);
                        if (entry.cccd_value != next_cccd_value) {
                            entry.cccd_value = next_cccd_value;
                            subscription_info = .{
                                .conn_handle = conn_handle,
                                .service_uuid = entry.svc_uuid,
                                .char_uuid = entry.char_uuid,
                                .cccd_value = next_cccd_value,
                            };
                        }
                    }
                    self.mutex.unlock();
                    if (subscription_info) |info| self.fireSubscriptionEvent(info);
                    if (needs_response) return att.encodeWriteResponse(out).len;
                    return 0;
                }
            }
            self.mutex.unlock();

            if (needs_response) return att.encodeErrorResponse(out, att.WRITE_REQUEST, attr_handle, .invalid_handle).len;
            return 0;
        }

        fn dispatchHandler(
            self: *Self,
            conn_handle: u16,
            char_entry: CharEntry,
            request_ctx: ?*anyopaque,
            request_handler: bt.RequestHandlerFn,
            op: bt.Operation,
            data: []const u8,
            out: []u8,
            needs_response: bool,
        ) usize {
            _ = self;

            var state = ResponseState{};
            var writer = bt.ResponseWriter{
                ._impl = &state,
                ._write_fn = ResponseState.writeFn,
                ._ok_fn = ResponseState.okFn,
                ._err_fn = ResponseState.errFn,
            };
            var req = bt.Request{
                .op = op,
                .conn_handle = conn_handle,
                .service_uuid = char_entry.svc_uuid,
                .char_uuid = char_entry.char_uuid,
                .data = data,
            };
            request_handler(request_ctx, &req, &writer);

            if (state.err_code) |code| {
                if (!needs_response) return 0;
                const request_opcode: u8 = switch (op) {
                    .read => att.READ_REQUEST,
                    .write => att.WRITE_REQUEST,
                    .write_without_response => att.WRITE_COMMAND,
                };
                return att.encodeErrorResponse(out, request_opcode, char_entry.value_handle, code).len;
            }

            if (!needs_response) return 0;
            return switch (op) {
                .read => att.encodeReadResponse(out, state.data[0..state.len]).len,
                .write, .write_without_response => att.encodeWriteResponse(out).len,
            };
        }

        fn findServiceByStartHandleLocked(self: *Self, attr_handle: u16) ?ServiceEntry {
            for (self.services.items) |service| {
                if (service.start_handle == attr_handle) return service;
            }
            return null;
        }

        fn findCharByDeclHandleLocked(self: *Self, attr_handle: u16) ?CharEntry {
            for (self.chars.items) |entry| {
                if (entry.decl_handle == attr_handle) return entry;
            }
            return null;
        }

        fn findCharByValueHandleLocked(self: *Self, attr_handle: u16) ?CharEntry {
            for (self.chars.items) |entry| {
                if (entry.value_handle == attr_handle) return entry;
            }
            return null;
        }

        fn findCharByCccdHandleLocked(self: *Self, attr_handle: u16) ?CharEntry {
            for (self.chars.items) |entry| {
                if (entry.cccd_handle == attr_handle) return entry;
            }
            return null;
        }

        fn attRequestHandle(data: []const u8) u16 {
            if (data.len >= 3) return glib.std.mem.readInt(u16, data[1..][0..2], .little);
            return 0x0000;
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const Impl = make(grt);
            const findCharHandle = struct {
                fn get(peripheral: *Impl, char_uuid: u16) ?u16 {
                    for (peripheral.chars.items) |entry| {
                        if (entry.char_uuid == char_uuid) return entry.value_handle;
                    }
                    return null;
                }
            }.get;

            {
                var peripheral = Impl{
                    .hci = undefined,
                    .allocator = grt.std.testing.allocator,
                };
                defer peripheral.chars.deinit(grt.std.testing.allocator);
                defer peripheral.hooks.deinit(grt.std.testing.allocator);
                defer peripheral.services.deinit(grt.std.testing.allocator);

                peripheral.setConfig(.{
                    .services = &.{
                        bt.Service(0x180D, &.{
                            bt.Char(0x2A37, bt.CharConfig.default()),
                            bt.Char(0x2A38, bt.CharConfig.default()),
                        }),
                    },
                });

                try grt.std.testing.expectEqual(@as(?u16, 3), findCharHandle(&peripheral, 0x2A37));
                try grt.std.testing.expectEqual(@as(?u16, 6), findCharHandle(&peripheral, 0x2A38));

                const dummy_a = struct {
                    fn handler(_: ?*anyopaque, _: *const bt.Request, _: *bt.ResponseWriter) void {}
                };
                const dummy_b = struct {
                    fn handler(_: ?*anyopaque, _: *const bt.Request, _: *bt.ResponseWriter) void {}
                };

                peripheral.setRequestHandler(null, dummy_a.handler);
                try grt.std.testing.expectEqual(@as(?bt.RequestHandlerFn, dummy_a.handler), peripheral.request_handler);
                peripheral.setRequestHandler(null, dummy_b.handler);
                try grt.std.testing.expectEqual(@as(?bt.RequestHandlerFn, dummy_b.handler), peripheral.request_handler);
            }

            {
                var peripheral = Impl{
                    .hci = undefined,
                    .allocator = grt.std.testing.allocator,
                };
                defer peripheral.chars.deinit(grt.std.testing.allocator);
                defer peripheral.hooks.deinit(grt.std.testing.allocator);
                defer peripheral.services.deinit(grt.std.testing.allocator);

                const dummy = struct {
                    fn handler(_: ?*anyopaque, _: *const bt.Request, rw: *bt.ResponseWriter) void {
                        rw.ok();
                    }
                };

                peripheral.setConfig(.{
                    .services = &.{
                        bt.Service(0x180D, &.{
                            bt.Char(0x2A37, (bt.CharConfig{}).withRead().withNotify()),
                            bt.Char(0x2A38, (bt.CharConfig{}).withWrite()),
                        }),
                    },
                });
                peripheral.setRequestHandler(null, dummy.handler);

                try grt.std.testing.expectEqual(@as(u8, 0x12), peripheral.chars.items[0].config.properties());
                try grt.std.testing.expect(peripheral.chars.items[0].cccd_handle != 0);
                try grt.std.testing.expectEqual(@as(u8, 0x08), peripheral.chars.items[1].config.properties());
                try grt.std.testing.expectEqual(@as(u16, 0), peripheral.chars.items[1].cccd_handle);

                var out: [att.MAX_PDU_LEN]u8 = undefined;

                const read_denied_len = peripheral.handleRead(1, peripheral.chars.items[1].value_handle, &out);
                switch (att.decodePdu(out[0..read_denied_len]).?) {
                    .error_response => |err| try grt.std.testing.expectEqual(att.ErrorCode.read_not_permitted, err.error_code),
                    else => return error.ExpectedReadNotPermitted,
                }

                const write_denied_len = peripheral.handleWrite(
                    1,
                    .write,
                    peripheral.chars.items[0].value_handle,
                    "x",
                    &out,
                    true,
                );
                switch (att.decodePdu(out[0..write_denied_len]).?) {
                    .error_response => |err| try grt.std.testing.expectEqual(att.ErrorCode.write_not_permitted, err.error_code),
                    else => return error.ExpectedWriteNotPermitted,
                }
            }

            {
                var peripheral = Impl{
                    .hci = undefined,
                    .allocator = grt.std.testing.allocator,
                };
                defer peripheral.chars.deinit(grt.std.testing.allocator);
                defer peripheral.hooks.deinit(grt.std.testing.allocator);
                defer peripheral.services.deinit(grt.std.testing.allocator);

                peripheral.setConfig(.{
                    .services = &.{
                        bt.Service(0x180D, &.{
                            bt.Char(0x2A37, (bt.CharConfig{}).withNotify()),
                        }),
                    },
                });

                var out: [att.MAX_PDU_LEN]u8 = undefined;
                const resp_len = peripheral.handleWrite(
                    1,
                    .write,
                    peripheral.chars.items[0].cccd_handle,
                    &.{0x01},
                    &out,
                    true,
                );
                switch (att.decodePdu(out[0..resp_len]).?) {
                    .error_response => |err| try grt.std.testing.expectEqual(att.ErrorCode.invalid_attribute_value_length, err.error_code),
                    else => return error.ExpectedInvalidLength,
                }
            }
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
