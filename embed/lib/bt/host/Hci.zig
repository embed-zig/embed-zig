//! Hci — HCI host coordinator.
//!
//! Holds a Transport, runs the event loop, and dispatches HCI events
//! through the protocol layers (GAP, L2CAP, ATT, GATT).
//!
//! Takes `comptime grt: type` for platform primitives (Thread, Mutex, time).

const glib = @import("glib");

const Transport = @import("../Transport.zig");
const Api = @import("../Hci.zig");
const commands = @import("hci/commands.zig");
const events = @import("hci/events.zig");
const acl_mod = @import("hci/acl.zig");
const Status = @import("hci/status.zig").Status;
const l2cap = @import("l2cap.zig");
const att = @import("att.zig");
const Gap = @import("Gap.zig");

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const Role = Gap.Role;
        const supervision_timeout_unit: glib.time.duration.Duration = 10 * glib.time.duration.MilliSecond;
        const AttResponseState = struct {
            data: [att.MAX_PDU_LEN]u8 = undefined,
            len: usize = 0,
            ready: bool = false,
            waiting: bool = false,
            request_opcode: u8 = 0,
        };

        pub const Config = struct {
            spawn_config: grt.std.Thread.SpawnConfig = .{
                .stack_size = 4096,
            },
            transport_read_timeout: glib.time.duration.Duration = 100 * glib.time.duration.MilliSecond,
            transport_write_timeout: glib.time.duration.Duration = 200 * glib.time.duration.MilliSecond,
            command_timeout: glib.time.duration.Duration = glib.time.duration.Second,
            att_response_timeout: glib.time.duration.Duration = 5 * glib.time.duration.Second,
        };

        transport: Transport,
        config: Config = .{},
        gap: Gap = Gap.init(),
        central_reassembler: l2cap.Reassembler = .{},
        peripheral_reassembler: l2cap.Reassembler = .{},
        mutex: grt.std.Thread.Mutex = .{},
        cond: grt.std.Thread.Condition = .{},
        running: bool = false,
        initialized: bool = false,
        recv_thread: ?grt.std.Thread = null,
        active_roles: u8 = 0,
        async_error: ?Api.Error = null,
        dispatching_peripheral_att: bool = false,

        // command flow control
        cmd_credits: u8 = 1,
        pending_opcode: u16 = 0,
        cmd_complete: bool = false,
        cmd_status: Status = .success,
        cmd_return_params: [64]u8 = undefined,
        cmd_return_len: usize = 0,

        central_callbacks: Api.CentralListener = .{},
        peripheral_callbacks: Api.PeripheralListener = .{},
        central_att_response: AttResponseState = .{},
        peripheral_att_response: AttResponseState = .{},

        pub fn init(transport: Transport, config: Config) Self {
            return .{
                .transport = transport,
                .config = config,
            };
        }

        pub fn retain(self: *Self) Api.Error!void {
            var need_start = false;
            self.mutex.lock();
            if (self.active_roles == 0 and self.recv_thread == null) {
                need_start = true;
            }
            self.active_roles += 1;
            self.mutex.unlock();
            if (need_start) {
                self.start() catch |err| {
                    self.mutex.lock();
                    glib.std.debug.assert(self.active_roles != 0);
                    self.active_roles -= 1;
                    self.mutex.unlock();
                    return mapError(err);
                };
            }
        }

        pub fn release(self: *Self) void {
            var need_stop = false;
            self.mutex.lock();
            if (self.active_roles > 0) self.active_roles -= 1;
            need_stop = self.active_roles == 0;
            self.mutex.unlock();
            if (need_stop) self.stop();
        }

        pub fn setCentralListener(self: *Self, listener: Api.CentralListener) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.central_callbacks = listener;
            if (listener.on_adv_report == null and listener.on_connected == null and listener.on_disconnected == null and listener.on_notification == null) {
                self.central_att_response = .{};
            }
        }

        pub fn setPeripheralListener(self: *Self, listener: Api.PeripheralListener) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.peripheral_callbacks = listener;
            if (listener.on_connected == null and listener.on_disconnected == null and listener.on_att_request == null) {
                self.peripheral_att_response = .{};
            }
        }

        /// Initialize the controller: reset, read BD_ADDR, set event masks.
        pub fn start(self: *Self) !void {
            self.mutex.lock();
            if (self.recv_thread != null) {
                self.mutex.unlock();
                return;
            }
            self.running = true;
            self.initialized = false;
            self.async_error = null;
            self.mutex.unlock();

            self.transport.setReadDeadline(null);
            const thread = try grt.std.Thread.spawn(self.config.spawn_config, recvLoop, .{self});
            self.mutex.lock();
            self.recv_thread = thread;
            self.mutex.unlock();
            errdefer self.stop();

            try self.sendCommandSync(commands.RESET, &.{});
            try self.sendCommandSync(commands.READ_BD_ADDR, &.{});
            if (self.cmd_status.isSuccess() and self.cmd_return_len >= 6) {
                self.mutex.lock();
                @memcpy(&self.gap.bd_addr, self.cmd_return_params[0..6]);
                self.gap.addr_known = true;
                self.mutex.unlock();
            }

            // Set event mask to receive LE Meta, Disconnection Complete, etc.
            var mask_buf: [8]u8 = undefined;
            grt.std.mem.writeInt(u64, &mask_buf, 0x20001FFFFFFFFFFF, .little);
            try self.sendCommandSync(commands.SET_EVENT_MASK, &mask_buf);

            var le_mask_buf: [8]u8 = undefined;
            grt.std.mem.writeInt(u64, &le_mask_buf, 0x000000000000001F, .little);
            try self.sendCommandSync(commands.LE_SET_EVENT_MASK, &le_mask_buf);

            self.initialized = true;
        }

        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.running = false;
            self.initialized = false;
            self.async_error = null;
            self.cond.broadcast();
            self.mutex.unlock();
            self.transport.setReadDeadline(grt.time.instant.now());

            if (self.recv_thread) |t| {
                t.join();
                self.recv_thread = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.stop();
        }

        // --- Command interface ---

        pub fn sendCommand(self: *Self, opcode: u16, params: []const u8) Api.Error!void {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const pkt = commands.encode(&buf, opcode, params);
            try self.acquireCommandCredit();
            _ = self.transportWrite(pkt) catch |err| return mapError(err);
        }

        /// Send a command and wait for Command Complete.
        pub fn sendCommandSync(self: *Self, opcode: u16, params: []const u8) !void {
            self.mutex.lock();
            self.pending_opcode = opcode;
            self.cmd_complete = false;
            self.cmd_status = .success;
            self.cmd_return_len = 0;
            self.mutex.unlock();

            try self.sendCommand(opcode, params);

            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.cmd_complete) {
                if (self.async_error) |err| return err;
                if (!self.running) return error.Disconnected;
                self.cond.timedWait(&self.mutex, try durationToTimedWaitNs(self.config.command_timeout)) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                };
            }
        }

        /// Send an ACL data packet (L2CAP over ATT).
        pub fn sendAcl(self: *Self, conn_handle: u16, att_data: []const u8) Api.Error!void {
            var buf: [l2cap.Reassembler.MAX_SDU_LEN + acl_mod.MAX_PACKET_LEN]u8 = undefined;
            var iter = l2cap.fragmentIterator(&buf, att_data, conn_handle, acl_mod.LE_DEFAULT_DATA_LEN);
            while (iter.next()) |fragment| {
                _ = self.transportWrite(fragment) catch |err| return mapError(err);
            }
        }

        /// Send an ATT request and wait for the response.
        pub fn sendAttRequest(self: *Self, conn_handle: u16, att_req: []const u8, out: []u8) Api.Error!usize {
            const role = self.connectionRole(conn_handle) orelse return error.Unexpected;
            self.mutex.lock();
            if (role == .peripheral and self.dispatching_peripheral_att) {
                self.mutex.unlock();
                return error.Unexpected;
            }
            const response = self.attStateForRole(role);
            response.ready = false;
            response.len = 0;
            response.waiting = true;
            response.request_opcode = if (att_req.len > 0) att_req[0] else 0;
            self.mutex.unlock();

            self.sendAcl(conn_handle, att_req) catch |err| {
                self.mutex.lock();
                self.attStateForRole(role).waiting = false;
                self.mutex.unlock();
                return err;
            };

            self.mutex.lock();
            defer {
                self.attStateForRole(role).waiting = false;
                self.mutex.unlock();
            }
            const wait_state = self.attStateForRole(role);
            while (!wait_state.ready) {
                if (self.async_error) |err| return err;
                if (!self.running) return error.Disconnected;
                if (self.gap.getRoleForHandle(conn_handle) == null) return error.Disconnected;
                self.cond.timedWait(&self.mutex, try durationToTimedWaitNs(self.config.att_response_timeout)) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                };
            }
            const n = @min(wait_state.len, out.len);
            @memcpy(out[0..n], wait_state.data[0..n]);
            wait_state.ready = false;
            return n;
        }

        // --- Receive loop (runs on dedicated thread) ---

        fn recvLoop(self: *Self) void {
            var buf: [1024]u8 = undefined;
            while (true) {
                self.mutex.lock();
                const still_running = self.running;
                self.mutex.unlock();
                if (!still_running) break;

                const n = self.transportRead(&buf) catch |err| switch (err) {
                    error.Timeout => continue,
                    else => {
                        self.mutex.lock();
                        self.running = false;
                        self.async_error = mapError(err);
                        self.cond.broadcast();
                        self.mutex.unlock();
                        break;
                    },
                };
                if (n == 0) continue;

                const raw = buf[0..n];
                if (raw[0] == events.INDICATOR) {
                    self.handleHciEvent(raw);
                } else if (raw[0] == acl_mod.INDICATOR) {
                    self.handleAclData(raw);
                }
            }
        }

        fn handleHciEvent(self: *Self, raw: []const u8) void {
            const evt = events.decode(raw) orelse return;
            var disconnect_role: ?Role = null;
            self.mutex.lock();
            if (evt == .disconnection_complete) {
                disconnect_role = self.gap.getRoleForHandle(evt.disconnection_complete.conn_handle);
            }
            self.gap.handleEvent(evt);
            const central_callbacks = self.central_callbacks;
            const peripheral_callbacks = self.peripheral_callbacks;
            self.mutex.unlock();

            switch (evt) {
                .command_complete => |cc| {
                    self.mutex.lock();
                    if (cc.opcode == self.pending_opcode) {
                        self.cmd_status = cc.status;
                        const n = @min(cc.return_params.len, self.cmd_return_params.len);
                        @memcpy(self.cmd_return_params[0..n], cc.return_params[0..n]);
                        self.cmd_return_len = n;
                        self.cmd_complete = true;
                    }
                    self.cmd_credits = cc.num_cmd_packets;
                    self.cond.broadcast();
                    self.mutex.unlock();
                },
                .command_status => |cs| {
                    self.mutex.lock();
                    if (cs.opcode == self.pending_opcode) {
                        self.cmd_status = cs.status;
                        self.cmd_complete = true;
                    }
                    self.cmd_credits = cs.num_cmd_packets;
                    self.cond.broadcast();
                    self.mutex.unlock();
                },
                .le_connection_complete => |lc| {
                    self.mutex.lock();
                    self.cond.broadcast();
                    self.mutex.unlock();
                    if (!lc.status.isSuccess()) return;
                    const link = eventLinkToApi(lc);
                    switch (if (lc.role == 0x00) Role.central else Role.peripheral) {
                        .central => if (central_callbacks.on_connected) |cb| cb(central_callbacks.ctx, link),
                        .peripheral => if (peripheral_callbacks.on_connected) |cb| cb(peripheral_callbacks.ctx, link),
                    }
                },
                .disconnection_complete => |dc| {
                    self.mutex.lock();
                    self.cond.broadcast();
                    self.mutex.unlock();
                    if (disconnect_role) |resolved_role| {
                        switch (resolved_role) {
                            .central => if (central_callbacks.on_disconnected) |cb| cb(central_callbacks.ctx, dc.conn_handle, @intFromEnum(dc.reason)),
                            .peripheral => if (peripheral_callbacks.on_disconnected) |cb| cb(peripheral_callbacks.ctx, dc.conn_handle, @intFromEnum(dc.reason)),
                        }
                    }
                },
                .le_advertising_report => |report| {
                    if (central_callbacks.on_adv_report) |cb| cb(central_callbacks.ctx, report.data);
                },
                else => {},
            }
        }

        fn handleAclData(self: *Self, raw: []const u8) void {
            const hdr = acl_mod.parsePacketHeader(raw) orelse return;
            const payload = acl_mod.getPayload(raw) orelse return;

            self.mutex.lock();
            const role = self.gap.getRoleForHandle(hdr.conn_handle) orelse {
                self.mutex.unlock();
                return;
            };
            const reassembler = switch (role) {
                .central => &self.central_reassembler,
                .peripheral => &self.peripheral_reassembler,
            };
            const sdu = reassembler.feed(hdr, payload);
            self.mutex.unlock();

            const resolved_sdu = sdu orelse return;
            if (resolved_sdu.cid == l2cap.CID_ATT) {
                self.handleAttPdu(resolved_sdu.conn_handle, resolved_sdu.data);
            }
        }

        fn handleAttPdu(self: *Self, conn_handle: u16, data: []const u8) void {
            if (data.len == 0) return;
            const opcode = data[0];
            self.mutex.lock();
            const role = self.gap.getRoleForHandle(conn_handle);
            const central_callbacks = self.central_callbacks;
            const peripheral_callbacks = self.peripheral_callbacks;
            self.mutex.unlock();

            if (opcode == att.HANDLE_VALUE_NOTIFICATION) {
                if (role == .central and data.len >= 3) {
                    const handle = grt.std.mem.readInt(u16, data[1..3], .little);
                    if (central_callbacks.on_notification) |cb| cb(central_callbacks.ctx, conn_handle, handle, data[3..]);
                }
                return;
            }

            if (opcode == att.HANDLE_VALUE_INDICATION) {
                var conf_buf: [1]u8 = undefined;
                const conf = att.encodeConfirmation(&conf_buf);
                self.sendAcl(conn_handle, conf) catch {};
                if (role == .central and data.len >= 3) {
                    const handle = grt.std.mem.readInt(u16, data[1..3], .little);
                    if (central_callbacks.on_notification) |cb| cb(central_callbacks.ctx, conn_handle, handle, data[3..]);
                }
                return;
            }

            if (isAttResponseOpcode(opcode)) {
                if (role) |resolved_role| {
                    self.mutex.lock();
                    const response = self.attStateForRole(resolved_role);
                    if (response.waiting and attResponseMatches(response.request_opcode, data)) {
                        const n = @min(data.len, response.data.len);
                        @memcpy(response.data[0..n], data[0..n]);
                        response.len = n;
                        response.ready = true;
                        response.waiting = false;
                        self.cond.broadcast();
                    }
                    self.mutex.unlock();
                }
                return;
            }

            if (role == .peripheral) {
                if (peripheral_callbacks.on_att_request) |cb| {
                    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
                    self.mutex.lock();
                    self.dispatching_peripheral_att = true;
                    self.mutex.unlock();
                    const resp_len = cb(peripheral_callbacks.ctx, conn_handle, data, &resp_buf);
                    self.mutex.lock();
                    self.dispatching_peripheral_att = false;
                    self.mutex.unlock();
                    if (resp_len > 0) {
                        self.sendAcl(conn_handle, resp_buf[0..resp_len]) catch {};
                    }
                    return;
                }
            }

            if (attNeedsResponse(opcode)) {
                var err_buf: [5]u8 = undefined;
                const err = att.encodeErrorResponse(&err_buf, opcode, attErrorHandle(data), .request_not_supported);
                self.sendAcl(conn_handle, err) catch {};
            }
        }

        /// Drain pending GAP commands and send them over Transport.
        pub fn flushGapCommands(self: *Self) Api.Error!void {
            while (true) {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                const cmd = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    const next = self.gap.nextCommand() orelse break :blk null;
                    @memcpy(cmd_buf[0..next.len], next);
                    break :blk cmd_buf[0..next.len];
                } orelse return;
                try self.acquireCommandCredit();
                _ = self.transportWrite(cmd) catch |err| return mapError(err);
            }
        }

        fn transportRead(self: *Self, buf: []u8) Transport.ReadError!usize {
            self.transport.setReadDeadline(self.ioDeadline(self.config.transport_read_timeout));
            return self.transport.read(buf);
        }

        fn transportWrite(self: *Self, buf: []const u8) Transport.WriteError!usize {
            self.transport.setWriteDeadline(self.ioDeadline(self.config.transport_write_timeout));
            return self.transport.write(buf);
        }

        fn ioDeadline(self: *const Self, timeout: glib.time.duration.Duration) glib.time.instant.Time {
            _ = self;
            return glib.time.instant.add(grt.time.instant.now(), timeout);
        }

        pub fn startScanning(self: *Self, config: Api.ScanConfig) Api.Error!void {
            self.mutex.lock();
            if (self.gap.isScanning()) {
                self.mutex.unlock();
                return error.Busy;
            }
            self.gap.startScanning(.{
                .active = config.active,
                .interval = config.interval,
                .window = config.window,
                .filter_duplicates = config.filter_duplicates,
            });
            self.mutex.unlock();
            try self.flushGapCommands();
        }

        pub fn stopScanning(self: *Self) void {
            self.mutex.lock();
            if (!self.gap.isScanning()) {
                self.mutex.unlock();
                return;
            }
            self.gap.stopScanning();
            self.mutex.unlock();
            self.flushGapCommands() catch {};
        }

        pub fn startAdvertising(self: *Self, config: Api.AdvConfig) Api.Error!void {
            self.mutex.lock();
            if (self.gap.isAdvertising()) {
                self.mutex.unlock();
                return error.Busy;
            }
            self.gap.startAdvertising(.{
                .interval_min = config.interval_min,
                .interval_max = config.interval_max,
                .connectable = config.connectable,
                .adv_data = config.adv_data,
                .scan_rsp_data = config.scan_rsp_data,
            });
            self.mutex.unlock();
            try self.flushGapCommands();
        }

        pub fn stopAdvertising(self: *Self) void {
            self.mutex.lock();
            if (!self.gap.isAdvertising()) {
                self.mutex.unlock();
                return;
            }
            self.gap.stopAdvertising();
            self.mutex.unlock();
            self.flushGapCommands() catch {};
        }

        pub fn connect(self: *Self, addr: Api.BdAddr, addr_type: Api.AddrType, config: Api.ConnConfig) Api.Error!void {
            self.mutex.lock();
            if (self.gap.isConnectingCentral() or self.gap.getLink(.central) != null) {
                self.mutex.unlock();
                return error.Busy;
            }
            self.gap.connect(addr, switch (addr_type) {
                .public => .public,
                .random => .random,
            }, .{
                .scan_interval = config.scan_interval,
                .scan_window = config.scan_window,
                .interval_min = config.interval_min,
                .interval_max = config.interval_max,
                .latency = config.latency,
                .supervision_timeout_units = durationToSupervisionTimeoutUnits(config.supervision_timeout),
            });
            self.mutex.unlock();
            try self.flushGapCommands();
        }

        pub fn cancelConnect(self: *Self) void {
            self.mutex.lock();
            if (!self.gap.isConnectingCentral()) {
                self.mutex.unlock();
                return;
            }
            self.gap.cancelConnect();
            self.mutex.unlock();
            self.flushGapCommands() catch {};
        }

        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) void {
            self.mutex.lock();
            self.gap.disconnect(conn_handle, reason);
            self.mutex.unlock();
            self.flushGapCommands() catch {};
        }

        pub fn getAddr(self: *Self) ?Api.BdAddr {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.gap.addr_known) return null;
            return self.gap.bd_addr;
        }

        pub fn getLink(self: *Self, role: Api.Role) ?Api.Link {
            self.mutex.lock();
            defer self.mutex.unlock();
            return gapLinkToApi(switch (role) {
                .central => self.gap.getLink(.central),
                .peripheral => self.gap.getLink(.peripheral),
            });
        }

        pub fn getLinkByHandle(self: *Self, conn_handle: u16) ?Api.Link {
            self.mutex.lock();
            defer self.mutex.unlock();
            return gapLinkToApi(self.gap.getLinkByHandle(conn_handle));
        }

        pub fn isScanning(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.gap.isScanning();
        }

        pub fn isAdvertising(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.gap.isAdvertising();
        }

        pub fn isConnectingCentral(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.gap.isConnectingCentral();
        }

        fn isAttResponseOpcode(opcode: u8) bool {
            return switch (opcode) {
                att.ERROR_RESPONSE,
                att.EXCHANGE_MTU_RESPONSE,
                att.FIND_INFORMATION_RESPONSE,
                att.READ_BY_TYPE_RESPONSE,
                att.READ_BY_GROUP_TYPE_RESPONSE,
                att.READ_RESPONSE,
                att.READ_BLOB_RESPONSE,
                att.WRITE_RESPONSE,
                att.HANDLE_VALUE_CONFIRMATION,
                => true,
                else => false,
            };
        }

        fn attResponseMatches(request_opcode: u8, response: []const u8) bool {
            if (response.len == 0) return false;
            const response_opcode = response[0];
            if (response_opcode == att.ERROR_RESPONSE) {
                const pdu = att.decodePdu(response) orelse return false;
                return switch (pdu) {
                    .error_response => |err| err.request_opcode == request_opcode,
                    else => false,
                };
            }
            return switch (request_opcode) {
                att.EXCHANGE_MTU_REQUEST => response_opcode == att.EXCHANGE_MTU_RESPONSE,
                att.FIND_INFORMATION_REQUEST => response_opcode == att.FIND_INFORMATION_RESPONSE,
                att.READ_BY_TYPE_REQUEST => response_opcode == att.READ_BY_TYPE_RESPONSE,
                att.READ_BY_GROUP_TYPE_REQUEST => response_opcode == att.READ_BY_GROUP_TYPE_RESPONSE,
                att.READ_REQUEST => response_opcode == att.READ_RESPONSE,
                att.WRITE_REQUEST => response_opcode == att.WRITE_RESPONSE,
                att.HANDLE_VALUE_INDICATION => response_opcode == att.HANDLE_VALUE_CONFIRMATION,
                else => false,
            };
        }

        fn attNeedsResponse(opcode: u8) bool {
            return switch (opcode) {
                att.WRITE_COMMAND => false,
                att.EXCHANGE_MTU_REQUEST,
                att.FIND_INFORMATION_REQUEST,
                att.READ_BY_TYPE_REQUEST,
                att.READ_BY_GROUP_TYPE_REQUEST,
                att.READ_REQUEST,
                att.READ_BLOB_REQUEST,
                att.WRITE_REQUEST,
                att.PREPARE_WRITE_REQUEST,
                att.EXECUTE_WRITE_REQUEST,
                => true,
                else => false,
            };
        }

        fn attErrorHandle(data: []const u8) u16 {
            if (data.len >= 3) {
                return grt.std.mem.readInt(u16, data[1..3], .little);
            }
            return 0x0000;
        }

        fn connectionRole(self: *Self, conn_handle: u16) ?Role {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.gap.getRoleForHandle(conn_handle);
        }

        fn acquireCommandCredit(self: *Self) Api.Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.cmd_credits == 0) {
                if (self.async_error) |err| return err;
                if (!self.running) return error.Disconnected;
                self.cond.timedWait(&self.mutex, try durationToTimedWaitNs(self.config.command_timeout)) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                };
            }
            self.cmd_credits -= 1;
        }

        fn durationToTimedWaitNs(timeout: glib.time.duration.Duration) Api.Error!u64 {
            if (timeout <= 0) return error.Timeout;
            return @intCast(timeout);
        }

        fn attStateForRole(self: *Self, role: Role) *AttResponseState {
            return switch (role) {
                .central => &self.central_att_response,
                .peripheral => &self.peripheral_att_response,
            };
        }

        fn gapLinkToApi(link: ?Gap.Link) ?Api.Link {
            const resolved = link orelse return null;
            return .{
                .role = switch (resolved.role) {
                    .central => .central,
                    .peripheral => .peripheral,
                },
                .conn_handle = resolved.conn_handle,
                .peer_addr = resolved.peer_addr,
                .peer_addr_type = switch (resolved.peer_addr_type) {
                    0x00, 0x02 => .public,
                    else => .random,
                },
                .interval = resolved.conn_interval,
                .latency = resolved.conn_latency,
                .supervision_timeout = supervisionTimeoutDuration(resolved.supervision_timeout_units),
            };
        }

        fn eventLinkToApi(link: events.LeConnectionComplete) Api.Link {
            return .{
                .role = if (link.role == 0x00) .central else .peripheral,
                .conn_handle = link.conn_handle,
                .peer_addr = link.peer_addr,
                .peer_addr_type = switch (link.peer_addr_type) {
                    0x00, 0x02 => .public,
                    else => .random,
                },
                .interval = link.conn_interval,
                .latency = link.conn_latency,
                .supervision_timeout = supervisionTimeoutDuration(link.supervision_timeout),
            };
        }

        fn durationToSupervisionTimeoutUnits(timeout: glib.time.duration.Duration) u16 {
            if (timeout <= 0) return 0;
            const units = @divFloor(timeout - 1, supervision_timeout_unit) + 1;
            return @intCast(@min(units, glib.std.math.maxInt(u16)));
        }

        fn supervisionTimeoutDuration(units: u16) glib.time.duration.Duration {
            return @as(glib.time.duration.Duration, @intCast(units)) * supervision_timeout_unit;
        }

        fn mapError(err: anyerror) Api.Error {
            return switch (err) {
                error.Busy => error.Busy,
                error.Timeout => error.Timeout,
                error.Rejected => error.Rejected,
                error.Disconnected => error.Disconnected,
                error.HwError => error.HwError,
                else => error.Unexpected,
            };
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            {
                const Impl = make(grt);

                const Counter = struct {
                    fn onDisconnected(ctx: ?*anyopaque, _: u16, _: u8) void {
                        const counter: *u32 = @ptrCast(@alignCast(ctx.?));
                        counter.* += 1;
                    }
                };

                var central_disconnects: u32 = 0;
                var peripheral_disconnects: u32 = 0;
                var hci = Impl.init(undefined, .{});
                hci.central_callbacks = .{
                    .ctx = &central_disconnects,
                    .on_disconnected = Counter.onDisconnected,
                };
                hci.peripheral_callbacks = .{
                    .ctx = &peripheral_disconnects,
                    .on_disconnected = Counter.onDisconnected,
                };

                hci.handleHciEvent(&.{ 0x04, 0x05, 0x04, 0x00, 0x40, 0x00, 0x13 });

                try grt.std.testing.expectEqual(@as(u32, 0), central_disconnects);
                try grt.std.testing.expectEqual(@as(u32, 0), peripheral_disconnects);
            }

            {
                const Impl = make(grt);

                const Counter = struct {
                    fn onConnected(ctx: ?*anyopaque, _: Api.Link) void {
                        const counter: *u32 = @ptrCast(@alignCast(ctx.?));
                        counter.* += 1;
                    }
                };

                var connected_count: u32 = 0;
                var hci = Impl.init(undefined, .{});
                hci.central_callbacks = .{
                    .ctx = &connected_count,
                    .on_connected = Counter.onConnected,
                };

                hci.handleHciEvent(&.{ 0x04, 0x3E, 0x13, 0x01, 0x08, 0x40, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x18, 0x00, 0x00, 0x00, 0xC8, 0x00 });

                try grt.std.testing.expectEqual(@as(u32, 0), connected_count);
            }

            {
                const Impl = make(grt);
                var err_buf: [att.MAX_PDU_LEN]u8 = undefined;
                const mismatched = att.encodeErrorResponse(&err_buf, att.FIND_INFORMATION_REQUEST, 0x0001, .request_not_supported);
                try grt.std.testing.expect(!Impl.attResponseMatches(att.WRITE_REQUEST, mismatched));
                try grt.std.testing.expect(Impl.attResponseMatches(att.FIND_INFORMATION_REQUEST, mismatched));
            }

            {
                const Impl = make(grt);
                try grt.std.testing.expectError(error.Timeout, Impl.durationToTimedWaitNs(0));
                try grt.std.testing.expectError(error.Timeout, Impl.durationToTimedWaitNs(-glib.time.duration.NanoSecond));
                try grt.std.testing.expectEqual(@as(u64, @intCast(3 * glib.time.duration.MilliSecond)), try Impl.durationToTimedWaitNs(3 * glib.time.duration.MilliSecond));
            }

            {
                const Impl = make(grt);
                const FakeTransport = struct {
                    read_deadline: ?glib.time.instant.Time = null,
                    write_deadline: ?glib.time.instant.Time = null,
                    read_calls: usize = 0,
                    write_calls: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                        _ = buf;
                        self.read_calls += 1;
                        return 0;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Transport.WriteError!usize {
                        self.write_calls += 1;
                        return buf.len;
                    }

                    pub fn reset(_: *@This()) void {}

                    pub fn deinit(_: *@This()) void {}

                    pub fn setReadDeadline(self: *@This(), deadline: ?glib.time.instant.Time) void {
                        self.read_deadline = deadline;
                    }

                    pub fn setWriteDeadline(self: *@This(), deadline: ?glib.time.instant.Time) void {
                        self.write_deadline = deadline;
                    }
                };

                var fake = FakeTransport{};
                var hci = Impl.init(Transport.init(&fake), .{
                    .transport_read_timeout = 13 * glib.time.duration.MilliSecond,
                    .transport_write_timeout = 17 * glib.time.duration.MilliSecond,
                });

                const read_timeout = hci.config.transport_read_timeout;
                const before_read = grt.time.instant.now();
                var read_buf: [1]u8 = undefined;
                try grt.std.testing.expectEqual(@as(usize, 0), try hci.transportRead(&read_buf));
                const after_read = grt.time.instant.now();
                const read_deadline = fake.read_deadline orelse return error.MissingReadDeadline;
                try grt.std.testing.expect(read_deadline >= glib.time.instant.add(before_read, read_timeout));
                try grt.std.testing.expect(read_deadline <= glib.time.instant.add(after_read, read_timeout));
                try grt.std.testing.expectEqual(@as(usize, 1), fake.read_calls);

                const write_timeout = hci.config.transport_write_timeout;
                const before_write = grt.time.instant.now();
                try grt.std.testing.expectEqual(@as(usize, 3), try hci.transportWrite("abc"));
                const after_write = grt.time.instant.now();
                const write_deadline = fake.write_deadline orelse return error.MissingWriteDeadline;
                try grt.std.testing.expect(write_deadline >= glib.time.instant.add(before_write, write_timeout));
                try grt.std.testing.expect(write_deadline <= glib.time.instant.add(after_write, write_timeout));
                try grt.std.testing.expectEqual(@as(usize, 1), fake.write_calls);

                const before_stop = grt.time.instant.now();
                hci.stop();
                const after_stop = grt.time.instant.now();
                const stop_deadline = fake.read_deadline orelse return error.MissingStopReadDeadline;
                try grt.std.testing.expect(stop_deadline >= before_stop);
                try grt.std.testing.expect(stop_deadline <= after_stop);
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
