//! mocker.Hci — protocol-level mock Bluetooth controller for tests.
//!
//! Implements the `Transport` contract and emulates a minimal LE controller:
//! - HCI command handling (`Reset`, `Read BD_ADDR`, scan/adv/connect/disconnect)
//! - LE Advertising Report + LE Connection Complete events
//! - ACL/L2CAP/ATT request handling against a built-in mock GATT database
//!
//! This is not a fake `Central` or fake `Peripheral`. It acts like a chip
//! that speaks HCI packets, so the host stack can be exercised end-to-end
//! without external hardware.

const std = @import("std");
const BtHci = @import("../Hci.zig");
const Central = @import("../Central.zig");
const Transport = @import("../Transport.zig");
const hci_commands = @import("../host/hci/commands.zig");
const hci_events = @import("../host/hci/events.zig");
const hci_acl = @import("../host/hci/acl.zig");
const hci_status = @import("../host/hci/status.zig").Status;
const l2cap = @import("../host/l2cap.zig");
const att = @import("../host/att.zig");
const gatt_client = @import("../host/gatt/client.zig");
const testing_api = @import("testing");

pub fn Hci(comptime lib: type) type {
    return struct {
        const Self = @This();
        const PROP_READ: u8 = 0x02;
        const PROP_WRITE_NO_RSP: u8 = 0x04;
        const PROP_WRITE: u8 = 0x08;
        const PROP_NOTIFY: u8 = 0x10;
        const PROP_INDICATE: u8 = 0x20;
        const NS_PER_MS: u64 = 1_000_000;
        const DEFAULT_RECV_TIMEOUT_MS: u32 = 10;
        const DEFAULT_PEER_TIMEOUT_MS: u32 = 500;
        const CCCD_DISCOVERY_MAX_ATTEMPTS: u32 = 3;

        pub const CharacteristicConfig = struct {
            uuid: u16,
            properties: u8 = PROP_READ | PROP_WRITE | PROP_NOTIFY,
            value: []const u8 = "mock-value",
        };

        pub const ServiceConfig = struct {
            uuid: u16,
            chars: []const CharacteristicConfig,
        };

        pub const default_services = [_]ServiceConfig{
            .{
                .uuid = 0x180D,
                .chars = &[_]CharacteristicConfig{
                    .{
                        .uuid = 0x2A37,
                        .properties = PROP_READ | PROP_WRITE | PROP_NOTIFY,
                        .value = "72",
                    },
                },
            },
        };

        pub const Config = struct {
            controller_addr: [6]u8 = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
            controller_addr_type: hci_commands.PeerAddrType = .public,
            peer_addr: [6]u8 = .{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 },
            peer_addr_type: hci_commands.PeerAddrType = .public,
            peer_name: []const u8 = "Hci",
            peer_rssi: i8 = -42,
            conn_handle: u16 = 0x0040,
            mtu: u16 = 247,
            services: []const ServiceConfig = &default_services,
            auto_advertise_on_scan: bool = true,
            recv_timeout_ms: ?u32 = DEFAULT_RECV_TIMEOUT_MS,
            peer_timeout_ms: u32 = DEFAULT_PEER_TIMEOUT_MS,
        };

        pub const PeerError = error{
            AlreadyConnected,
            NotAdvertising,
            NotConnected,
            Timeout,
            AttError,
            Unexpected,
        };

        pub const ServerPush = struct {
            kind: Kind,
            handle: u16,
            data: [att.MAX_PDU_LEN]u8 = undefined,
            len: usize = 0,

            pub const Kind = enum {
                notification,
                indication,
            };

            pub fn payload(self: *const ServerPush) []const u8 {
                return self.data[0..self.len];
            }
        };

        pub const WorldHooks = struct {
            ctx: ?*anyopaque = null,
            on_scan_started: ?*const fn (?*anyopaque, *Self, BtHci.ScanConfig) void = null,
            on_adv_state_changed: ?*const fn (?*anyopaque, *Self, bool) void = null,
            on_connect_requested: ?*const fn (?*anyopaque, *Self, BtHci.BdAddr, BtHci.AddrType, BtHci.ConnConfig) BtHci.Error!void = null,
        };

        const LinkState = struct {
            active: bool = false,
            peer: ?*Self = null,
        };

        const ServiceState = struct {
            uuid: u16,
            start_handle: u16,
            end_handle: u16,
            first_char_index: usize,
            char_count: usize,
        };

        const CharState = struct {
            service_index: usize,
            uuid: u16,
            properties: u8,
            decl_handle: u16,
            value_handle: u16,
            cccd_handle: u16,
            cccd_value: u16 = 0,
            initial_value: []const u8,
            value: std.ArrayListUnmanaged(u8) = .{},
        };

        const Packet = struct {
            buf: [1024]u8 = undefined,
            len: usize = 0,
        };

        const InternalError = error{
            OutOfMemory,
            InvalidPacket,
        };

        allocator: lib.mem.Allocator,
        mutex: lib.Thread.Mutex = .{},
        queue: std.ArrayListUnmanaged(Packet) = .{},
        host_server_pushes: std.ArrayListUnmanaged(ServerPush) = .{},
        services: std.ArrayListUnmanaged(ServiceState) = .{},
        chars: std.ArrayListUnmanaged(CharState) = .{},
        acl_reassembler: l2cap.Reassembler = .{},
        config: Config,
        default_recv_timeout_ms: ?u32,
        read_deadline_ns: ?i64 = null,
        write_deadline_ns: ?i64 = null,
        peer_att_response: [att.MAX_PDU_LEN]u8 = undefined,
        peer_att_response_len: usize = 0,
        peer_att_response_ready: bool = false,
        host_adv_data: [31]u8 = undefined,
        host_adv_data_len: usize = 0,
        host_scan_rsp_data: [31]u8 = undefined,
        host_scan_rsp_data_len: usize = 0,
        scan_enabled: bool = false,
        adv_enabled: bool = false,
        central_link: LinkState = .{},
        peripheral_link: LinkState = .{},
        default_peer: ?*Self = null,
        world_hooks: WorldHooks = .{},
        hci_refs: usize = 0,
        central_listener: BtHci.CentralListener = .{},
        peripheral_listener: BtHci.PeripheralListener = .{},

        pub fn init(allocator: lib.mem.Allocator, config: Config) !Self {
            var self = Self{
                .allocator = allocator,
                .config = config,
                .default_recv_timeout_ms = config.recv_timeout_ms,
            };
            try self.buildDatabase();
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.chars.items) |*char| {
                char.value.deinit(self.allocator);
            }
            self.host_server_pushes.deinit(self.allocator);
            self.chars.deinit(self.allocator);
            self.services.deinit(self.allocator);
            self.queue.deinit(self.allocator);
        }

        pub fn asHci(self: *Self) BtHci {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub fn pairWith(self: *Self, peer: *Self) void {
            self.default_peer = peer;
        }

        pub fn clearPair(self: *Self) void {
            self.default_peer = null;
        }

        pub fn setWorldHooks(self: *Self, hooks: WorldHooks) void {
            self.world_hooks = hooks;
        }

        pub fn controllerAddr(self: *const Self) BtHci.BdAddr {
            return self.config.controller_addr;
        }

        pub fn controllerAddrType(self: *const Self) BtHci.AddrType {
            return self.localAddrType();
        }

        pub fn isScanningNode(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.scan_enabled;
        }

        pub fn isAdvertisingNode(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.adv_enabled;
        }

        pub fn fireCentralAdvReportFrom(self: *Self, advertiser: *const Self, rssi: i8) void {
            self.mutex.lock();
            const listener = self.central_listener;
            self.mutex.unlock();
            const cb = listener.on_adv_report orelse return;
            var buf: [64]u8 = undefined;
            const len = self.buildAdvReportDataForAdvertiser(advertiser, rssi, &buf);
            cb(listener.ctx, buf[0..len]);
        }

        pub fn establishPeerLink(self: *Self, peer: *Self) BtHci.Error!void {
            lockNodes(self, peer);
            defer unlockNodes(self, peer);

            if (self.hasLink(.central) or peer.hasLink(.peripheral)) return error.Busy;
            if (!peer.adv_enabled) return error.Rejected;

            self.activateLink(.central, peer);
            peer.activateLink(.peripheral, self);

            const self_handle = self.connHandleForRole(.central);
            const peer_handle = peer.connHandleForRole(.peripheral);

            unlockNodes(self, peer);
            self.fireConnected(.central, self_handle);
            peer.fireConnected(.peripheral, peer_handle);
            lockNodes(self, peer);
        }

        const vtable = BtHci.VTable{
            .retain = retainVTable,
            .release = releaseVTable,
            .setCentralListener = setCentralListenerVTable,
            .setPeripheralListener = setPeripheralListenerVTable,
            .startScanning = startScanningVTable,
            .stopScanning = stopScanningVTable,
            .startAdvertising = startAdvertisingVTable,
            .stopAdvertising = stopAdvertisingVTable,
            .connect = connectVTable,
            .cancelConnect = cancelConnectVTable,
            .disconnect = disconnectVTable,
            .sendAcl = sendAclVTable,
            .sendAttRequest = sendAttRequestVTable,
            .getAddr = getAddrVTable,
            .getLink = getLinkVTable,
            .getLinkByHandle = getLinkByHandleVTable,
            .isScanning = isScanningVTable,
            .isAdvertising = isAdvertisingVTable,
            .isConnectingCentral = isConnectingCentralVTable,
            .deinit = deinitVTable,
        };

        fn retainVTable(ptr: *anyopaque) BtHci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.retainHci();
        }

        fn releaseVTable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.releaseHci();
        }

        fn setCentralListenerVTable(ptr: *anyopaque, listener: BtHci.CentralListener) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.setCentralListenerHci(listener);
        }

        fn setPeripheralListenerVTable(ptr: *anyopaque, listener: BtHci.PeripheralListener) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.setPeripheralListenerHci(listener);
        }

        fn startScanningVTable(ptr: *anyopaque, config: BtHci.ScanConfig) BtHci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.startScanningHci(config);
        }

        fn stopScanningVTable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopScanningHci();
        }

        fn startAdvertisingVTable(ptr: *anyopaque, config: BtHci.AdvConfig) BtHci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.startAdvertisingHci(config);
        }

        fn stopAdvertisingVTable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.stopAdvertisingHci();
        }

        fn connectVTable(ptr: *anyopaque, addr: BtHci.BdAddr, addr_type: BtHci.AddrType, config: BtHci.ConnConfig) BtHci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.connectHci(addr, addr_type, config);
        }

        fn cancelConnectVTable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.cancelConnectHci();
        }

        fn disconnectVTable(ptr: *anyopaque, conn_handle: u16, reason: u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.disconnectHci(conn_handle, reason);
        }

        fn sendAclVTable(ptr: *anyopaque, conn_handle: u16, data: []const u8) BtHci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.sendAclHci(conn_handle, data);
        }

        fn sendAttRequestVTable(ptr: *anyopaque, conn_handle: u16, req: []const u8, out: []u8) BtHci.Error!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.sendAttRequestHci(conn_handle, req, out);
        }

        fn getAddrVTable(ptr: *anyopaque) ?BtHci.BdAddr {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.getAddrHci();
        }

        fn getLinkVTable(ptr: *anyopaque, role: BtHci.Role) ?BtHci.Link {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.getLinkHci(role);
        }

        fn getLinkByHandleVTable(ptr: *anyopaque, conn_handle: u16) ?BtHci.Link {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.getLinkByHandleHci(conn_handle);
        }

        fn isScanningVTable(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isScanningHci();
        }

        fn isAdvertisingVTable(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isAdvertisingHci();
        }

        fn isConnectingCentralVTable(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.isConnectingCentralHci();
        }

        fn deinitVTable(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn retainHci(self: *Self) BtHci.Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.hci_refs += 1;
        }

        fn releaseHci(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.hci_refs > 0) self.hci_refs -= 1;
        }

        fn setCentralListenerHci(self: *Self, listener: BtHci.CentralListener) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.central_listener = listener;
        }

        fn setPeripheralListenerHci(self: *Self, listener: BtHci.PeripheralListener) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.peripheral_listener = listener;
        }

        fn startScanningHci(self: *Self, config: BtHci.ScanConfig) BtHci.Error!void {
            self.mutex.lock();
            self.scan_enabled = true;
            self.mutex.unlock();
            if (self.world_hooks.on_scan_started) |cb| {
                cb(self.world_hooks.ctx, self, config);
                return;
            }
            if (self.default_peer != null or self.config.auto_advertise_on_scan) {
                self.fireCentralAdvReport();
            }
        }

        fn stopScanningHci(self: *Self) void {
            self.mutex.lock();
            self.scan_enabled = false;
            self.mutex.unlock();
        }

        fn startAdvertisingHci(self: *Self, config: BtHci.AdvConfig) BtHci.Error!void {
            self.mutex.lock();
            self.host_adv_data_len = @min(config.adv_data.len, self.host_adv_data.len);
            if (self.host_adv_data_len > 0) {
                @memcpy(self.host_adv_data[0..self.host_adv_data_len], config.adv_data[0..self.host_adv_data_len]);
            }
            self.host_scan_rsp_data_len = @min(config.scan_rsp_data.len, self.host_scan_rsp_data.len);
            if (self.host_scan_rsp_data_len > 0) {
                @memcpy(self.host_scan_rsp_data[0..self.host_scan_rsp_data_len], config.scan_rsp_data[0..self.host_scan_rsp_data_len]);
            }
            self.adv_enabled = true;
            self.mutex.unlock();
            if (self.world_hooks.on_adv_state_changed) |cb| {
                cb(self.world_hooks.ctx, self, true);
                return;
            }
            if (self.default_peer) |peer| {
                if (peer.scan_enabled) peer.fireCentralAdvReport();
            }
        }

        fn stopAdvertisingHci(self: *Self) void {
            self.mutex.lock();
            self.adv_enabled = false;
            self.mutex.unlock();
            if (self.world_hooks.on_adv_state_changed) |cb| {
                cb(self.world_hooks.ctx, self, false);
            }
        }

        fn connectHci(self: *Self, addr: BtHci.BdAddr, addr_type: BtHci.AddrType, config: BtHci.ConnConfig) BtHci.Error!void {
            if (self.hasLink(.central)) return error.Busy;
            if (self.world_hooks.on_connect_requested) |cb| {
                return cb(self.world_hooks.ctx, self, addr, addr_type, config);
            }
            if (self.default_peer) |peer| {
                if (peer.localAddrType() != addr_type) return error.Rejected;
                if (!std.mem.eql(u8, &addr, &peer.config.controller_addr)) return error.Rejected;
                return self.establishPeerLink(peer);
            }
            if (addrTypeFromConfig(self.config.peer_addr_type) != addr_type) return error.Rejected;
            if (!std.mem.eql(u8, &addr, &self.config.peer_addr)) return error.Rejected;

            self.activateLink(.central, null);
            self.fireConnected(.central, self.connHandleForRole(.central));
        }

        fn cancelConnectHci(self: *Self) void {
            _ = self;
        }

        fn disconnectHci(self: *Self, conn_handle: u16, reason: u8) void {
            self.mutex.lock();
            const role = self.roleForHandle(conn_handle) orelse {
                self.mutex.unlock();
                return;
            };
            const peer = self.peerForRole(role);
            self.mutex.unlock();

            if (peer) |p| {
                lockNodes(self, p);
                defer unlockNodes(self, p);

                if (self.roleForHandle(conn_handle) != role) return;

                self.clearLink(role);
                const peer_role = oppositeRole(role);
                const peer_should_disconnect = p.hasLink(peer_role) and p.peerForRole(peer_role) == self;
                const peer_handle = p.connHandleForRole(peer_role);
                if (peer_should_disconnect) p.clearLink(peer_role);

                unlockNodes(self, p);
                self.fireDisconnected(role, conn_handle, reason);
                if (peer_should_disconnect) p.fireDisconnected(peer_role, peer_handle, reason);
                lockNodes(self, p);
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.roleForHandle(conn_handle) != role) return;
            self.clearLink(role);
            self.mutex.unlock();
            self.fireDisconnected(role, conn_handle, reason);
            self.mutex.lock();
        }

        fn sendAclHci(self: *Self, conn_handle: u16, data: []const u8) BtHci.Error!void {
            const role = self.roleForHandle(conn_handle) orelse return error.Disconnected;
            if (self.peerForRole(role)) |peer| {
                peer.receiveAclFromPeer(oppositeRole(role), data) catch return error.Unexpected;
                return;
            }
            self.handleOutboundAtt(data) catch return error.Unexpected;
        }

        fn sendAttRequestHci(self: *Self, conn_handle: u16, req: []const u8, out: []u8) BtHci.Error!usize {
            const role = self.roleForHandle(conn_handle) orelse return error.Disconnected;
            if (self.peerForRole(role)) |peer| {
                return peer.handleAttFromPeer(oppositeRole(role), req, out) catch return error.Unexpected;
            }

            if (att.decodePdu(req)) |pdu| {
                switch (pdu) {
                    .indication => |ind| {
                        self.recordServerPush(.indication, ind.handle, ind.value) catch return error.Unexpected;
                        return att.encodeConfirmation(out).len;
                    },
                    .notification => |notif| {
                        self.recordServerPush(.notification, notif.handle, notif.value) catch return error.Unexpected;
                        return 0;
                    },
                    else => {},
                }
            }

            return self.handleAttRequest(req, out) catch return error.Unexpected;
        }

        fn getAddrHci(self: *Self) ?BtHci.BdAddr {
            return self.config.controller_addr;
        }

        fn getLinkHci(self: *Self, role: BtHci.Role) ?BtHci.Link {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.hasLink(role)) return null;
            return self.makeLink(role);
        }

        fn getLinkByHandleHci(self: *Self, conn_handle: u16) ?BtHci.Link {
            self.mutex.lock();
            defer self.mutex.unlock();
            const role = self.roleForHandle(conn_handle) orelse return null;
            return self.makeLink(role);
        }

        fn isScanningHci(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.scan_enabled;
        }

        fn isAdvertisingHci(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.adv_enabled;
        }

        fn isConnectingCentralHci(self: *Self) bool {
            _ = self;
            return false;
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.clearRetainingCapacity();
            self.host_server_pushes.clearRetainingCapacity();
            self.peer_att_response_len = 0;
            self.peer_att_response_ready = false;
            self.scan_enabled = false;
            self.adv_enabled = false;
            self.central_link = .{};
            self.peripheral_link = .{};
            self.host_adv_data_len = 0;
            self.host_scan_rsp_data_len = 0;
            self.acl_reassembler.reset();

            for (self.chars.items) |*char| {
                char.cccd_value = 0;
                char.value.clearRetainingCapacity();
                char.value.appendSlice(self.allocator, char.initial_value) catch {};
            }
        }

        pub fn write(self: *Self, buf: []const u8) Transport.WriteError!usize {
            self.handleHostPacket(buf) catch |err| return switch (err) {
                error.InvalidPacket => error.HwError,
                error.OutOfMemory => error.Unexpected,
            };
            return buf.len;
        }

        pub fn read(self: *Self, out: []u8) Transport.ReadError!usize {
            const deadline_ns = self.effectiveReadDeadlineNs();
            while (true) {
                self.mutex.lock();
                if (self.queue.items.len > 0) {
                    const packet = self.queue.orderedRemove(0);
                    self.mutex.unlock();

                    const n = @min(packet.len, out.len);
                    @memcpy(out[0..n], packet.buf[0..n]);
                    return n;
                }
                self.mutex.unlock();

                if (deadline_ns) |deadline| {
                    if (nowNs(lib) >= deadline) return error.Timeout;
                }
                lib.Thread.sleep(NS_PER_MS);
            }
        }

        pub fn setReadDeadline(self: *Self, deadline_ns: ?i64) void {
            self.read_deadline_ns = deadline_ns;
        }

        pub fn setWriteDeadline(self: *Self, deadline_ns: ?i64) void {
            self.write_deadline_ns = deadline_ns;
        }

        pub fn getPeerAddr(self: *const Self) [6]u8 {
            if (self.default_peer) |peer| return peer.config.controller_addr;
            return self.config.peer_addr;
        }

        pub fn getHostAdvData(self: *const Self) []const u8 {
            return self.host_adv_data[0..self.host_adv_data_len];
        }

        pub fn getHostScanRspData(self: *const Self) []const u8 {
            return self.host_scan_rsp_data[0..self.host_scan_rsp_data_len];
        }

        pub fn notify(self: *Self, char_uuid: u16, value: []const u8) !void {
            if (!self.hasLink(.peripheral)) return;
            for (self.chars.items) |char| {
                if (char.uuid != char_uuid) continue;
                if (char.cccd_handle == 0 or (char.cccd_value & 0x0001) == 0) return;

                var pdu_buf: [att.MAX_PDU_LEN]u8 = undefined;
                const pdu = att.encodeNotification(&pdu_buf, char.value_handle, value);
                try self.enqueueAtt(self.connHandleForRole(.peripheral), pdu);
                self.fireCentralNotification(self.connHandleForRole(.central), char.value_handle, value);
                return;
            }
        }

        pub fn indicate(self: *Self, char_uuid: u16, value: []const u8) !void {
            if (!self.hasLink(.peripheral)) return;
            for (self.chars.items) |char| {
                if (char.uuid != char_uuid) continue;
                if (char.cccd_handle == 0 or (char.cccd_value & 0x0002) == 0) return;

                var pdu_buf: [att.MAX_PDU_LEN]u8 = undefined;
                const pdu = att.encodeIndication(&pdu_buf, char.value_handle, value);
                try self.enqueueAtt(self.connHandleForRole(.peripheral), pdu);
                self.fireCentralNotification(self.connHandleForRole(.central), char.value_handle, value);
                return;
            }
        }

        pub fn connect(self: *Self) PeerError!void {
            return self.connectAsCentral();
        }

        pub fn connectAsCentral(self: *Self) PeerError!void {
            if (self.hasLink(.peripheral)) return error.AlreadyConnected;
            if (!self.adv_enabled) return error.NotAdvertising;
            self.activateLink(.peripheral, null);
            self.enqueueLeConnectionCompleteForRole(.success, .peripheral) catch return error.Unexpected;
            self.fireConnected(.peripheral, self.connHandleForRole(.peripheral));
        }

        pub fn disconnect(self: *Self) PeerError!void {
            return self.disconnectAsCentral(hci_status.remote_user_terminated);
        }

        pub fn disconnectAsCentral(self: *Self, reason: hci_status) PeerError!void {
            if (!self.hasLink(.peripheral)) return error.NotConnected;
            const conn_handle = self.connHandleForRole(.peripheral);
            self.clearLink(.peripheral);
            self.enqueueDisconnectionComplete(conn_handle, reason) catch return error.Unexpected;
            self.fireDisconnected(.peripheral, conn_handle, @intFromEnum(reason));
        }

        pub fn popServerPush(self: *Self) ?ServerPush {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.host_server_pushes.items.len == 0) return null;
            return self.host_server_pushes.orderedRemove(0);
        }

        pub fn waitServerPush(self: *Self, timeout_ms: u32) ?ServerPush {
            var waited_ms: u32 = 0;
            while (waited_ms <= timeout_ms) : (waited_ms += 1) {
                if (self.popServerPush()) |push| return push;
                lib.Thread.sleep(NS_PER_MS);
            }
            return null;
        }

        pub fn exchangeMtu(self: *Self, mtu: u16) PeerError!u16 {
            return self.exchangeMtuWithHost(mtu);
        }

        pub fn exchangeMtuWithHost(self: *Self, mtu: u16) PeerError!u16 {
            var req_buf: [3]u8 = undefined;
            const req = att.encodeMtuRequest(&req_buf, mtu);
            const resp = try self.sendAttToHostExpectResponse(req);
            const pdu = att.decodePdu(resp) orelse return error.Unexpected;
            return switch (pdu) {
                .exchange_mtu_response => |mtu_resp| mtu_resp.server_mtu,
                .error_response => error.AttError,
                else => error.Unexpected,
            };
        }

        pub fn discoverServices(self: *Self, out: []Central.DiscoveredService) PeerError!usize {
            return self.discoverHostServices(out);
        }

        pub fn discoverHostServices(self: *Self, out: []Central.DiscoveredService) PeerError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeDiscoverServices(&req_buf, 0x0001);
            const resp = try self.sendAttToHostExpectResponse(req);
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

        pub fn discoverChars(self: *Self, start_handle: u16, end_handle: u16, out: []Central.DiscoveredChar) PeerError!usize {
            return self.discoverHostChars(start_handle, end_handle, out);
        }

        pub fn discoverHostChars(self: *Self, start_handle: u16, end_handle: u16, out: []Central.DiscoveredChar) PeerError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeDiscoverChars(&req_buf, start_handle, end_handle);
            const resp = try self.sendAttToHostExpectResponse(req);
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
                        if (try self.discoverHostCccd(cccd_start, cccd_end, &req_buf)) |cccd_handle| {
                            out[i].cccd_handle = cccd_handle;
                        }
                    }
                }
            }

            return n;
        }

        pub fn readAttr(self: *Self, handle: u16, out: []u8) PeerError!usize {
            return self.readHost(handle, out);
        }

        pub fn readHost(self: *Self, handle: u16, out: []u8) PeerError!usize {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeRead(&req_buf, handle);
            const resp = try self.sendAttToHostExpectResponse(req);
            if (gatt_client.isErrorFor(resp, att.READ_REQUEST)) |_| return error.AttError;
            return gatt_client.parseReadResponse(resp, out);
        }

        pub fn writeAttr(self: *Self, handle: u16, value: []const u8) PeerError!void {
            return self.writeHost(handle, value);
        }

        fn effectiveReadDeadlineNs(self: *const Self) ?i64 {
            if (self.read_deadline_ns) |deadline| return deadline;
            const timeout_ms = self.default_recv_timeout_ms orelse DEFAULT_RECV_TIMEOUT_MS;
            return nowNs(lib) + @as(i64, @intCast(timeout_ms)) * @as(i64, @intCast(NS_PER_MS));
        }

        fn nowNs(comptime l: type) i64 {
            return l.time.milliTimestamp() * @as(i64, @intCast(NS_PER_MS));
        }

        pub fn writeHost(self: *Self, handle: u16, value: []const u8) PeerError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeWrite(&req_buf, handle, value);
            const resp = try self.sendAttToHostExpectResponse(req);
            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn writeCommand(self: *Self, handle: u16, value: []const u8) PeerError!void {
            return self.writeHostCommand(handle, value);
        }

        pub fn writeHostCommand(self: *Self, handle: u16, value: []const u8) PeerError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = att.encodeWriteCommand(&req_buf, handle, value);
            try self.sendAttToHostNoResponse(req);
        }

        pub fn subscribeHost(self: *Self, cccd_handle: u16) PeerError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeSubscribe(&req_buf, cccd_handle);
            const resp = try self.sendAttToHostExpectResponse(req);
            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        pub fn unsubscribeHost(self: *Self, cccd_handle: u16) PeerError!void {
            var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const req = gatt_client.encodeUnsubscribe(&req_buf, cccd_handle);
            const resp = try self.sendAttToHostExpectResponse(req);
            if (gatt_client.isErrorFor(resp, att.WRITE_REQUEST)) |_| return error.AttError;
        }

        fn discoverHostCccd(self: *Self, start_handle: u16, end_handle: u16, req_buf: *[att.MAX_PDU_LEN]u8) PeerError!?u16 {
            var attempt: u32 = 0;
            while (attempt < CCCD_DISCOVERY_MAX_ATTEMPTS) : (attempt += 1) {
                const find_req = gatt_client.encodeFindCccd(req_buf, start_handle, end_handle);
                const find_resp = self.sendAttToHostExpectResponse(find_req) catch |err| switch (err) {
                    error.Timeout => {
                        if (attempt + 1 < CCCD_DISCOVERY_MAX_ATTEMPTS) {
                            lib.Thread.sleep(NS_PER_MS);
                            continue;
                        }
                        return error.Timeout;
                    },
                    else => return err,
                };

                if (gatt_client.isErrorFor(find_resp, att.FIND_INFORMATION_REQUEST)) |code| {
                    return switch (code) {
                        .attribute_not_found => null,
                        else => error.AttError,
                    };
                }
                return gatt_client.parseFindCccdResponse(find_resp);
            }
            return error.Timeout;
        }

        fn makeLink(self: *Self, role: BtHci.Role) BtHci.Link {
            return .{
                .role = role,
                .conn_handle = self.connHandleForRole(role),
                .peer_addr = self.remoteAddr(role),
                .peer_addr_type = self.remoteAddrType(role),
                .interval = 0x0018,
                .latency = 0,
                .timeout = 0x00C8,
            };
        }

        fn fireCentralAdvReport(self: *Self) void {
            self.mutex.lock();
            const listener = self.central_listener;
            self.mutex.unlock();
            const cb = listener.on_adv_report orelse return;
            var buf: [64]u8 = undefined;
            const len = if (self.default_peer) |peer|
                self.buildAdvReportDataForAdvertiser(peer, peer.config.peer_rssi, &buf)
            else
                self.buildAdvReportData(&buf);
            cb(listener.ctx, buf[0..len]);
        }

        fn fireConnected(self: *Self, role: BtHci.Role, conn_handle: u16) void {
            const link = self.makeLink(role);
            _ = conn_handle;
            switch (role) {
                .central => {
                    self.mutex.lock();
                    const listener = self.central_listener;
                    self.mutex.unlock();
                    if (listener.on_connected) |cb| cb(listener.ctx, link);
                },
                .peripheral => {
                    self.mutex.lock();
                    const listener = self.peripheral_listener;
                    self.mutex.unlock();
                    if (listener.on_connected) |cb| cb(listener.ctx, link);
                },
            }
        }

        fn fireDisconnected(self: *Self, role: BtHci.Role, conn_handle: u16, reason: u8) void {
            switch (role) {
                .central => {
                    self.mutex.lock();
                    const listener = self.central_listener;
                    self.mutex.unlock();
                    if (listener.on_disconnected) |cb| cb(listener.ctx, conn_handle, reason);
                },
                .peripheral => {
                    self.mutex.lock();
                    const listener = self.peripheral_listener;
                    self.mutex.unlock();
                    if (listener.on_disconnected) |cb| cb(listener.ctx, conn_handle, reason);
                },
            }
        }

        fn fireCentralNotification(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            if (!self.hasLink(.central) or conn_handle != self.connHandleForRole(.central)) return;
            self.mutex.lock();
            const listener = self.central_listener;
            self.mutex.unlock();
            if (listener.on_notification) |cb| cb(listener.ctx, conn_handle, attr_handle, value);
        }

        fn remoteAddr(self: *const Self, role: BtHci.Role) BtHci.BdAddr {
            if (self.peerForRole(role)) |peer| return peer.config.controller_addr;
            if (self.default_peer) |peer| return peer.config.controller_addr;
            return self.config.peer_addr;
        }

        fn remoteAddrType(self: *const Self, role: BtHci.Role) BtHci.AddrType {
            if (self.peerForRole(role)) |peer| return peer.localAddrType();
            if (self.default_peer) |peer| return peer.localAddrType();
            return addrTypeFromConfig(self.config.peer_addr_type);
        }

        fn localAddrType(self: *const Self) BtHci.AddrType {
            return addrTypeFromConfig(self.config.controller_addr_type);
        }

        fn oppositeRole(role: BtHci.Role) BtHci.Role {
            return switch (role) {
                .central => .peripheral,
                .peripheral => .central,
            };
        }

        fn buildAdvReportData(self: *Self, out: *[64]u8) usize {
            var adv_data: [31]u8 = undefined;
            const adv_len = self.buildAdvertisingData(&adv_data);

            out[0] = 1;
            out[1] = 0x00;
            out[2] = @intFromEnum(self.config.peer_addr_type);
            @memcpy(out[3..][0..6], &self.config.peer_addr);
            out[9] = @intCast(adv_len);
            if (adv_len > 0) {
                @memcpy(out[10..][0..adv_len], adv_data[0..adv_len]);
            }
            out[10 + adv_len] = @bitCast(self.config.peer_rssi);
            return 11 + adv_len;
        }

        fn buildAdvReportDataForAdvertiser(self: *const Self, advertiser: *const Self, rssi: i8, out: *[64]u8) usize {
            _ = self;
            const mutable_advertiser: *Self = @constCast(advertiser);
            mutable_advertiser.mutex.lock();
            defer mutable_advertiser.mutex.unlock();
            const adv_len = advertiser.host_adv_data_len;
            out[0] = 1;
            out[1] = 0x00;
            out[2] = @intFromEnum(advertiser.localAddrType());
            @memcpy(out[3..][0..6], &advertiser.config.controller_addr);
            out[9] = @intCast(adv_len);
            if (adv_len > 0) {
                @memcpy(out[10..][0..adv_len], advertiser.host_adv_data[0..adv_len]);
            }
            out[10 + adv_len] = @bitCast(rssi);
            return 11 + adv_len;
        }

        fn handleOutboundAtt(self: *Self, data: []const u8) !void {
            if (att.decodePdu(data)) |pdu| {
                switch (pdu) {
                    .notification => |notif| {
                        try self.recordServerPush(.notification, notif.handle, notif.value);
                    },
                    .indication => |ind| {
                        try self.recordServerPush(.indication, ind.handle, ind.value);
                    },
                    .error_response,
                    .exchange_mtu_response,
                    .read_by_group_type_response,
                    .read_by_type_response,
                    .find_information_response,
                    .read_response,
                    .write_response,
                    .confirmation,
                    => {
                        self.storePeerAttResponse(data);
                    },
                    else => {},
                }
            }
        }

        fn receiveAclFromPeer(self: *Self, role: BtHci.Role, data: []const u8) !void {
            if (att.decodePdu(data)) |pdu| {
                switch (pdu) {
                    .notification => |notif| {
                        if (role == .central) self.fireCentralNotification(self.connHandleForRole(.central), notif.handle, notif.value);
                    },
                    .indication => |ind| {
                        if (role == .central) self.fireCentralNotification(self.connHandleForRole(.central), ind.handle, ind.value);
                    },
                    .error_response,
                    .exchange_mtu_response,
                    .read_by_group_type_response,
                    .read_by_type_response,
                    .find_information_response,
                    .read_response,
                    .write_response,
                    .confirmation,
                    => {
                        self.storePeerAttResponse(data);
                    },
                    .write_command => {
                        if (role == .peripheral) {
                            if (self.peripheral_listener.on_att_request) |cb| {
                                var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
                                _ = cb(self.peripheral_listener.ctx, self.connHandleForRole(.peripheral), data, &resp_buf);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        fn handleAttFromPeer(self: *Self, role: BtHci.Role, req: []const u8, out: []u8) !usize {
            const pdu = att.decodePdu(req) orelse return att.encodeErrorResponse(out, 0x00, 0x0000, .invalid_pdu).len;

            switch (role) {
                .central => {
                    return switch (pdu) {
                        .indication => |ind| blk: {
                            self.fireCentralNotification(self.connHandleForRole(.central), ind.handle, ind.value);
                            break :blk att.encodeConfirmation(out).len;
                        },
                        .notification => |notif| blk: {
                            self.fireCentralNotification(self.connHandleForRole(.central), notif.handle, notif.value);
                            break :blk 0;
                        },
                        else => 0,
                    };
                },
                .peripheral => {
                    if (self.peripheral_listener.on_att_request) |cb| {
                        return cb(self.peripheral_listener.ctx, self.connHandleForRole(.peripheral), req, out);
                    }
                    if (attRequestNeedsResponse(req[0])) {
                        return att.encodeErrorResponse(out, req[0], attRequestHandle(req), .request_not_supported).len;
                    }
                    return 0;
                },
            }
        }

        fn attRequestNeedsResponse(opcode: u8) bool {
            return switch (opcode) {
                att.WRITE_COMMAND,
                att.HANDLE_VALUE_NOTIFICATION,
                => false,
                else => true,
            };
        }

        fn attRequestHandle(data: []const u8) u16 {
            if (data.len >= 3) return std.mem.readInt(u16, data[1..][0..2], .little);
            return 0x0000;
        }

        fn addrTypeFromConfig(addr_type: hci_commands.PeerAddrType) BtHci.AddrType {
            return switch (addr_type) {
                .public => .public,
                else => .random,
            };
        }

        fn lockNodes(a: *Self, b: *Self) void {
            if (@intFromPtr(a) < @intFromPtr(b)) {
                a.mutex.lock();
                b.mutex.lock();
            } else if (@intFromPtr(a) > @intFromPtr(b)) {
                b.mutex.lock();
                a.mutex.lock();
            } else {
                a.mutex.lock();
            }
        }

        fn unlockNodes(a: *Self, b: *Self) void {
            if (@intFromPtr(a) < @intFromPtr(b)) {
                b.mutex.unlock();
                a.mutex.unlock();
            } else if (@intFromPtr(a) > @intFromPtr(b)) {
                a.mutex.unlock();
                b.mutex.unlock();
            } else {
                a.mutex.unlock();
            }
        }

        fn linkState(self: *Self, role: BtHci.Role) *LinkState {
            return switch (role) {
                .central => &self.central_link,
                .peripheral => &self.peripheral_link,
            };
        }

        fn linkStateConst(self: *const Self, role: BtHci.Role) *const LinkState {
            return switch (role) {
                .central => &self.central_link,
                .peripheral => &self.peripheral_link,
            };
        }

        fn hasLink(self: *const Self, role: BtHci.Role) bool {
            return self.linkStateConst(role).active;
        }

        fn peerForRole(self: *const Self, role: BtHci.Role) ?*Self {
            return self.linkStateConst(role).peer;
        }

        fn activateLink(self: *Self, role: BtHci.Role, peer: ?*Self) void {
            const link = self.linkState(role);
            link.active = true;
            link.peer = peer;
            if (role == .central) self.scan_enabled = false;
        }

        fn clearLink(self: *Self, role: BtHci.Role) void {
            self.linkState(role).* = .{};
        }

        fn connHandleForRole(self: *const Self, role: BtHci.Role) u16 {
            return switch (role) {
                .central => self.config.conn_handle,
                .peripheral => self.config.conn_handle + 1,
            };
        }

        fn roleForHandle(self: *const Self, conn_handle: u16) ?BtHci.Role {
            if (self.hasLink(.central) and conn_handle == self.connHandleForRole(.central)) return .central;
            if (self.hasLink(.peripheral) and conn_handle == self.connHandleForRole(.peripheral)) return .peripheral;
            return null;
        }

        fn buildDatabase(self: *Self) !void {
            var next_handle: u16 = 1;
            for (self.config.services) |service_cfg| {
                const first_char_index = self.chars.items.len;
                const start_handle = next_handle;
                next_handle += 1; // primary service declaration

                for (service_cfg.chars) |char_cfg| {
                    const decl_handle = next_handle;
                    next_handle += 1;
                    const value_handle = next_handle;
                    next_handle += 1;
                    const cccd_handle: u16 = if ((char_cfg.properties & (PROP_NOTIFY | PROP_INDICATE)) != 0) blk: {
                        const handle = next_handle;
                        next_handle += 1;
                        break :blk handle;
                    } else 0;

                    var char = CharState{
                        .service_index = self.services.items.len,
                        .uuid = char_cfg.uuid,
                        .properties = char_cfg.properties,
                        .decl_handle = decl_handle,
                        .value_handle = value_handle,
                        .cccd_handle = cccd_handle,
                        .initial_value = char_cfg.value,
                    };
                    try char.value.appendSlice(self.allocator, char_cfg.value);
                    try self.chars.append(self.allocator, char);
                }

                try self.services.append(self.allocator, .{
                    .uuid = service_cfg.uuid,
                    .start_handle = start_handle,
                    .end_handle = next_handle - 1,
                    .first_char_index = first_char_index,
                    .char_count = self.chars.items.len - first_char_index,
                });
            }
        }

        fn handleHostPacket(self: *Self, buf: []const u8) InternalError!void {
            if (buf.len == 0) return error.InvalidPacket;
            return switch (buf[0]) {
                hci_commands.INDICATOR => self.handleCommandPacket(buf),
                hci_acl.INDICATOR => self.handleAclPacket(buf),
                else => error.InvalidPacket,
            };
        }

        fn handleCommandPacket(self: *Self, raw: []const u8) InternalError!void {
            if (raw.len < 4) return error.InvalidPacket;
            const param_len: usize = raw[3];
            if (raw.len < 4 + param_len) return error.InvalidPacket;

            const opcode = std.mem.readInt(u16, raw[1..][0..2], .little);
            const params = raw[4 .. 4 + param_len];

            switch (opcode) {
                hci_commands.RESET => {
                    self.reset();
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.READ_BD_ADDR => {
                    try self.enqueueCommandComplete(opcode, .success, &self.config.controller_addr);
                },
                hci_commands.SET_EVENT_MASK,
                hci_commands.LE_SET_EVENT_MASK,
                hci_commands.LE_SET_SCAN_PARAMS,
                hci_commands.LE_SET_ADV_PARAMS,
                => {
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.LE_SET_ADV_DATA => {
                    if (params.len < 32) return error.InvalidPacket;
                    self.host_adv_data_len = @min(@as(usize, params[0]), self.host_adv_data.len);
                    if (self.host_adv_data_len > 0) {
                        @memcpy(self.host_adv_data[0..self.host_adv_data_len], params[1 .. 1 + self.host_adv_data_len]);
                    }
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.LE_SET_SCAN_RSP_DATA => {
                    if (params.len < 32) return error.InvalidPacket;
                    self.host_scan_rsp_data_len = @min(@as(usize, params[0]), self.host_scan_rsp_data.len);
                    if (self.host_scan_rsp_data_len > 0) {
                        @memcpy(self.host_scan_rsp_data[0..self.host_scan_rsp_data_len], params[1 .. 1 + self.host_scan_rsp_data_len]);
                    }
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.LE_SET_SCAN_ENABLE => {
                    if (params.len < 2) return error.InvalidPacket;
                    self.scan_enabled = params[0] != 0;
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                    if (self.scan_enabled and self.config.auto_advertise_on_scan) {
                        try self.enqueueAdvertisingReport();
                    }
                },
                hci_commands.LE_SET_ADV_ENABLE => {
                    if (params.len < 1) return error.InvalidPacket;
                    self.adv_enabled = params[0] != 0;
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.LE_CREATE_CONNECTION => {
                    if (params.len < 12) return error.InvalidPacket;
                    const peer_addr_type: hci_commands.PeerAddrType = @enumFromInt(params[5]);
                    const peer_addr = params[6..][0..6].*;

                    try self.enqueueCommandStatus(.success, opcode);
                    if (peer_addr_type == self.config.peer_addr_type and std.mem.eql(u8, &peer_addr, &self.config.peer_addr)) {
                        self.activateLink(.central, null);
                        try self.enqueueLeConnectionCompleteForRole(.success, .central);
                    } else {
                        try self.enqueueLeConnectionCompleteForRole(.connection_failed_to_establish, .central);
                    }
                },
                hci_commands.LE_CREATE_CONNECTION_CANCEL => {
                    try self.enqueueCommandComplete(opcode, .success, &.{});
                },
                hci_commands.DISCONNECT => {
                    if (params.len < 3) return error.InvalidPacket;
                    const conn_handle = std.mem.readInt(u16, params[0..][0..2], .little) & 0x0FFF;
                    const reason: hci_status = @enumFromInt(params[2]);

                    self.mutex.lock();
                    const role = self.roleForHandle(conn_handle);
                    const peer = if (role) |resolved_role| self.peerForRole(resolved_role) else null;
                    self.mutex.unlock();

                    const resolved_role = role orelse {
                        try self.enqueueCommandStatus(.no_connection, opcode);
                        return;
                    };

                    if (peer) |p| {
                        lockNodes(self, p);
                        defer unlockNodes(self, p);

                        const confirmed_role = self.roleForHandle(conn_handle) orelse {
                            try self.enqueueCommandStatus(.no_connection, opcode);
                            return;
                        };
                        const peer_role = oppositeRole(confirmed_role);
                        const peer_should_disconnect = p.hasLink(peer_role) and p.peerForRole(peer_role) == self;
                        const peer_handle = p.connHandleForRole(peer_role);

                        self.clearLink(confirmed_role);
                        if (peer_should_disconnect) p.clearLink(peer_role);

                        unlockNodes(self, p);
                        try self.enqueueCommandStatus(.success, opcode);
                        try self.enqueueDisconnectionComplete(conn_handle, reason);
                        if (peer_should_disconnect) try p.enqueueDisconnectionComplete(peer_handle, reason);
                        lockNodes(self, p);
                    } else {
                        self.mutex.lock();
                        self.clearLink(resolved_role);
                        self.mutex.unlock();
                        try self.enqueueCommandStatus(.success, opcode);
                        try self.enqueueDisconnectionComplete(conn_handle, reason);
                    }
                },
                else => {
                    try self.enqueueCommandComplete(opcode, .unknown_command, &.{});
                },
            }
        }

        fn handleAclPacket(self: *Self, raw: []const u8) InternalError!void {
            const hdr = hci_acl.parsePacketHeader(raw) orelse return error.InvalidPacket;
            const payload = hci_acl.getPayload(raw) orelse return error.InvalidPacket;
            const sdu = self.acl_reassembler.feed(hdr, payload) orelse return;
            if (sdu.cid != l2cap.CID_ATT) return;

            const pdu = att.decodePdu(sdu.data) orelse return;
            switch (pdu) {
                .notification => |notif| {
                    try self.recordServerPush(.notification, notif.handle, notif.value);
                    return;
                },
                .indication => |ind| {
                    try self.recordServerPush(.indication, ind.handle, ind.value);
                    var conf_buf: [1]u8 = undefined;
                    const conf = att.encodeConfirmation(&conf_buf);
                    try self.enqueueAtt(sdu.conn_handle, conf);
                    return;
                },
                .error_response,
                .exchange_mtu_response,
                .read_by_group_type_response,
                .read_by_type_response,
                .find_information_response,
                .read_response,
                .write_response,
                .confirmation,
                => {
                    self.storePeerAttResponse(sdu.data);
                    return;
                },
                else => {},
            }

            var out_buf: [att.MAX_PDU_LEN]u8 = undefined;
            const resp_len = self.handleAttRequest(sdu.data, &out_buf) catch return error.OutOfMemory;
            if (resp_len > 0) {
                try self.enqueueAtt(sdu.conn_handle, out_buf[0..resp_len]);
            }
        }

        fn handleAttRequest(self: *Self, data: []const u8, out: []u8) !usize {
            const pdu = att.decodePdu(data) orelse return 0;
            return switch (pdu) {
                .exchange_mtu_request => blk: {
                    const resp = att.encodeMtuResponse(out, self.config.mtu);
                    break :blk resp.len;
                },
                .read_by_group_type_request => |req| self.handleReadByGroupType(req, out),
                .read_by_type_request => |req| self.handleReadByType(req, out),
                .find_information_request => |req| self.handleFindInformation(req, out),
                .read_request => |req| self.handleRead(req.handle, out),
                .read_blob_request => |req| att.encodeErrorResponse(out, att.READ_BLOB_REQUEST, req.handle, .attribute_not_long).len,
                .write_request => |req| try self.handleWrite(req.handle, req.value, out, true),
                .write_command => |req| blk: {
                    _ = try self.handleWrite(req.handle, req.value, out, false);
                    break :blk 0;
                },
                .confirmation => 0,
                else => att.encodeErrorResponse(out, data[0], 0x0000, .request_not_supported).len,
            };
        }

        fn handleReadByGroupType(self: *Self, req: att.ReadByGroupTypeRequest, out: []u8) usize {
            if (req.uuid != .uuid16 or req.uuid.uuid16 != att.PRIMARY_SERVICE_UUID) {
                return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .unsupported_group_type).len;
            }

            var pos: usize = 2;
            for (self.services.items) |service| {
                if (service.start_handle < req.start_handle or service.start_handle > req.end_handle) continue;
                if (pos + 6 > out.len) break;

                std.mem.writeInt(u16, out[pos..][0..2], service.start_handle, .little);
                std.mem.writeInt(u16, out[pos + 2 ..][0..2], service.end_handle, .little);
                std.mem.writeInt(u16, out[pos + 4 ..][0..2], service.uuid, .little);
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

            var pos: usize = 2;
            for (self.chars.items) |char| {
                if (char.decl_handle < req.start_handle or char.decl_handle > req.end_handle) continue;
                if (pos + 7 > out.len) break;

                std.mem.writeInt(u16, out[pos..][0..2], char.decl_handle, .little);
                out[pos + 2] = char.properties;
                std.mem.writeInt(u16, out[pos + 3 ..][0..2], char.value_handle, .little);
                std.mem.writeInt(u16, out[pos + 5 ..][0..2], char.uuid, .little);
                pos += 7;
            }

            if (pos == 2) {
                return att.encodeErrorResponse(out, att.READ_BY_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.READ_BY_TYPE_RESPONSE;
            out[1] = 7;
            return pos;
        }

        fn handleFindInformation(self: *Self, req: att.FindInformationRequest, out: []u8) usize {
            var pos: usize = 2;

            for (self.services.items) |service| {
                if (service.start_handle >= req.start_handle and service.start_handle <= req.end_handle and pos + 4 <= out.len) {
                    std.mem.writeInt(u16, out[pos..][0..2], service.start_handle, .little);
                    std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.PRIMARY_SERVICE_UUID, .little);
                    pos += 4;
                }

                const end = service.first_char_index + service.char_count;
                for (self.chars.items[service.first_char_index..end]) |char| {
                    if (char.decl_handle >= req.start_handle and char.decl_handle <= req.end_handle and pos + 4 <= out.len) {
                        std.mem.writeInt(u16, out[pos..][0..2], char.decl_handle, .little);
                        std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.CHARACTERISTIC_UUID, .little);
                        pos += 4;
                    }
                    if (char.value_handle >= req.start_handle and char.value_handle <= req.end_handle and pos + 4 <= out.len) {
                        std.mem.writeInt(u16, out[pos..][0..2], char.value_handle, .little);
                        std.mem.writeInt(u16, out[pos + 2 ..][0..2], char.uuid, .little);
                        pos += 4;
                    }
                    if (char.cccd_handle != 0 and char.cccd_handle >= req.start_handle and char.cccd_handle <= req.end_handle and pos + 4 <= out.len) {
                        std.mem.writeInt(u16, out[pos..][0..2], char.cccd_handle, .little);
                        std.mem.writeInt(u16, out[pos + 2 ..][0..2], att.CCCD_UUID, .little);
                        pos += 4;
                    }
                }
            }

            if (pos == 2) {
                return att.encodeErrorResponse(out, att.FIND_INFORMATION_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.FIND_INFORMATION_RESPONSE;
            out[1] = 0x01;
            return pos;
        }

        fn handleRead(self: *Self, handle: u16, out: []u8) usize {
            for (self.services.items) |service| {
                if (service.start_handle == handle) {
                    out[0] = att.READ_RESPONSE;
                    std.mem.writeInt(u16, out[1..][0..2], service.uuid, .little);
                    return 3;
                }

                const end = service.first_char_index + service.char_count;
                for (self.chars.items[service.first_char_index..end]) |char| {
                    if (char.decl_handle == handle) {
                        out[0] = att.READ_RESPONSE;
                        out[1] = char.properties;
                        std.mem.writeInt(u16, out[2..][0..2], char.value_handle, .little);
                        std.mem.writeInt(u16, out[4..][0..2], char.uuid, .little);
                        return 6;
                    }
                    if (char.value_handle == handle) {
                        if ((char.properties & PROP_READ) == 0) {
                            return att.encodeErrorResponse(out, att.READ_REQUEST, handle, .read_not_permitted).len;
                        }
                        const resp = att.encodeReadResponse(out, char.value.items);
                        return resp.len;
                    }
                    if (char.cccd_handle != 0 and char.cccd_handle == handle) {
                        out[0] = att.READ_RESPONSE;
                        std.mem.writeInt(u16, out[1..][0..2], char.cccd_value, .little);
                        return 3;
                    }
                }
            }

            return att.encodeErrorResponse(out, att.READ_REQUEST, handle, .invalid_handle).len;
        }

        fn handleWrite(self: *Self, handle: u16, value: []const u8, out: []u8, needs_response: bool) !usize {
            for (self.chars.items) |*char| {
                if (char.value_handle == handle) {
                    if ((char.properties & (PROP_WRITE | PROP_WRITE_NO_RSP)) == 0) {
                        if (needs_response) return att.encodeErrorResponse(out, att.WRITE_REQUEST, handle, .write_not_permitted).len;
                        return 0;
                    }

                    char.value.clearRetainingCapacity();
                    try char.value.appendSlice(self.allocator, value);
                    if (needs_response) return att.encodeWriteResponse(out).len;
                    return 0;
                }

                if (char.cccd_handle != 0 and char.cccd_handle == handle) {
                    if (value.len >= 2) {
                        char.cccd_value = std.mem.readInt(u16, value[0..][0..2], .little);
                    }
                    if (needs_response) return att.encodeWriteResponse(out).len;
                    return 0;
                }
            }

            if (needs_response) return att.encodeErrorResponse(out, att.WRITE_REQUEST, handle, .invalid_handle).len;
            return 0;
        }

        fn sendAttToHostExpectResponse(self: *Self, pdu: []const u8) PeerError![]const u8 {
            if (!self.hasLink(.peripheral)) return error.NotConnected;

            self.mutex.lock();
            self.peer_att_response_len = 0;
            self.peer_att_response_ready = false;
            self.mutex.unlock();

            self.enqueueAtt(self.connHandleForRole(.peripheral), pdu) catch return error.Unexpected;

            var waited_ms: u32 = 0;
            while (true) {
                self.mutex.lock();
                const ready = self.peer_att_response_ready;
                self.mutex.unlock();
                if (ready) break;
                if (waited_ms >= self.config.peer_timeout_ms) return error.Timeout;
                lib.Thread.sleep(NS_PER_MS);
                waited_ms += 1;
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            return self.peer_att_response[0..self.peer_att_response_len];
        }

        fn sendAttToHostNoResponse(self: *Self, pdu: []const u8) PeerError!void {
            if (!self.hasLink(.peripheral)) return error.NotConnected;
            self.enqueueAtt(self.connHandleForRole(.peripheral), pdu) catch return error.Unexpected;
        }

        fn recordServerPush(self: *Self, kind: ServerPush.Kind, handle: u16, value: []const u8) !void {
            var push = ServerPush{
                .kind = kind,
                .handle = handle,
            };
            push.len = @min(value.len, push.data.len);
            if (push.len > 0) {
                @memcpy(push.data[0..push.len], value[0..push.len]);
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            try self.host_server_pushes.append(self.allocator, push);
        }

        fn storePeerAttResponse(self: *Self, data: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = @min(data.len, self.peer_att_response.len);
            @memcpy(self.peer_att_response[0..n], data[0..n]);
            self.peer_att_response_len = n;
            self.peer_att_response_ready = true;
        }

        fn enqueuePacket(self: *Self, data: []const u8) !void {
            var packet: Packet = .{};
            packet.len = @min(data.len, packet.buf.len);
            @memcpy(packet.buf[0..packet.len], data[0..packet.len]);
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(self.allocator, packet);
        }

        fn enqueueCommandComplete(self: *Self, opcode: u16, status: hci_status, return_params: []const u8) !void {
            var buf: [80]u8 = undefined;
            buf[0] = 0x04;
            buf[1] = 0x0E;
            buf[2] = @intCast(4 + return_params.len);
            buf[3] = 1; // num command packets
            std.mem.writeInt(u16, buf[4..][0..2], opcode, .little);
            buf[6] = @intFromEnum(status);
            if (return_params.len > 0) {
                @memcpy(buf[7..][0..return_params.len], return_params);
            }
            try self.enqueuePacket(buf[0 .. 7 + return_params.len]);
        }

        fn enqueueCommandStatus(self: *Self, status: hci_status, opcode: u16) !void {
            var buf: [7]u8 = undefined;
            buf[0] = 0x04;
            buf[1] = 0x0F;
            buf[2] = 0x04;
            buf[3] = @intFromEnum(status);
            buf[4] = 1;
            std.mem.writeInt(u16, buf[5..][0..2], opcode, .little);
            try self.enqueuePacket(&buf);
        }

        fn enqueueAdvertisingReport(self: *Self) !void {
            var adv_data: [31]u8 = undefined;
            const adv_len = self.buildAdvertisingData(&adv_data);

            var buf: [64]u8 = undefined;
            buf[0] = 0x04;
            buf[1] = 0x3E;
            buf[2] = @intCast(12 + adv_len);
            buf[3] = 0x02; // LE Advertising Report
            buf[4] = 1; // num reports
            buf[5] = 0x00; // ADV_IND
            buf[6] = @intFromEnum(self.config.peer_addr_type);
            @memcpy(buf[7..][0..6], &self.config.peer_addr);
            buf[13] = @intCast(adv_len);
            if (adv_len > 0) {
                @memcpy(buf[14..][0..adv_len], adv_data[0..adv_len]);
            }
            buf[14 + adv_len] = @bitCast(self.config.peer_rssi);
            try self.enqueuePacket(buf[0 .. 15 + adv_len]);
        }

        fn enqueueLeConnectionCompleteForRole(self: *Self, status: hci_status, role: BtHci.Role) !void {
            return self.enqueueLeConnectionComplete(
                status,
                switch (role) {
                    .central => 0x00,
                    .peripheral => 0x01,
                },
                self.connHandleForRole(role),
                self.remoteAddr(role),
                self.remoteAddrType(role),
            );
        }

        fn enqueueLeConnectionComplete(
            self: *Self,
            status: hci_status,
            role: u8,
            conn_handle: u16,
            peer_addr: BtHci.BdAddr,
            peer_addr_type: BtHci.AddrType,
        ) !void {
            var buf: [22]u8 = undefined;
            buf[0] = 0x04;
            buf[1] = 0x3E;
            buf[2] = 19;
            buf[3] = 0x01; // LE Connection Complete
            buf[4] = @intFromEnum(status);
            std.mem.writeInt(u16, buf[5..][0..2], conn_handle, .little);
            buf[7] = role;
            buf[8] = @intFromEnum(peer_addr_type);
            @memcpy(buf[9..][0..6], &peer_addr);
            std.mem.writeInt(u16, buf[15..][0..2], 0x0018, .little);
            std.mem.writeInt(u16, buf[17..][0..2], 0x0000, .little);
            std.mem.writeInt(u16, buf[19..][0..2], 0x00C8, .little);
            buf[21] = 0x00; // master clock accuracy
            try self.enqueuePacket(&buf);
        }

        fn enqueueDisconnectionComplete(self: *Self, conn_handle: u16, reason: hci_status) !void {
            var buf: [7]u8 = undefined;
            buf[0] = 0x04;
            buf[1] = 0x05;
            buf[2] = 0x04;
            buf[3] = @intFromEnum(hci_status.success);
            std.mem.writeInt(u16, buf[4..][0..2], conn_handle, .little);
            buf[6] = @intFromEnum(reason);
            try self.enqueuePacket(&buf);
        }

        fn enqueueAtt(self: *Self, conn_handle: u16, pdu: []const u8) !void {
            var buf: [l2cap.Reassembler.MAX_SDU_LEN + hci_acl.MAX_PACKET_LEN]u8 = undefined;
            var iter = l2cap.fragmentIterator(&buf, pdu, conn_handle, hci_acl.LE_DEFAULT_DATA_LEN);
            while (iter.next()) |fragment| {
                try self.enqueuePacket(fragment);
            }
        }

        fn buildAdvertisingData(self: *Self, out: *[31]u8) usize {
            var pos: usize = 0;

            if (pos + 3 <= out.len) {
                out[pos] = 0x02;
                out[pos + 1] = 0x01;
                out[pos + 2] = 0x06;
                pos += 3;
            }

            const max_uuids = if (pos + 2 <= out.len) (out.len - pos - 2) / 2 else 0;
            const uuid_count = @min(self.services.items.len, max_uuids);
            if (uuid_count > 0) {
                out[pos] = @intCast(uuid_count * 2 + 1);
                out[pos + 1] = 0x03;
                pos += 2;
                for (self.services.items[0..uuid_count]) |service| {
                    std.mem.writeInt(u16, out[pos..][0..2], service.uuid, .little);
                    pos += 2;
                }
            }

            if (self.config.peer_name.len > 0 and pos + 2 <= out.len) {
                const remaining = out.len - pos;
                if (remaining > 2) {
                    const name_len = @min(self.config.peer_name.len, remaining - 2);
                    out[pos] = @intCast(name_len + 1);
                    out[pos + 1] = 0x09;
                    @memcpy(out[pos + 2 ..][0..name_len], self.config.peer_name[0..name_len]);
                    pos += 2 + name_len;
                }
            }

            return pos;
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const Mock = Hci(lib);

            {
                const CentralState = struct {
                    saw_adv: bool = false,
                    connected: bool = false,
                    disconnected: bool = false,

                    fn onAdv(ctx: ?*anyopaque, _: []const u8) void {
                        const self: *@This() = @ptrCast(@alignCast(ctx.?));
                        self.saw_adv = true;
                    }
                    fn onConnected(ctx: ?*anyopaque, _: BtHci.Link) void {
                        const self: *@This() = @ptrCast(@alignCast(ctx.?));
                        self.connected = true;
                    }
                    fn onDisconnected(ctx: ?*anyopaque, _: u16, _: u8) void {
                        const self: *@This() = @ptrCast(@alignCast(ctx.?));
                        self.disconnected = true;
                    }
                };

                const PeripheralState = struct {
                    connected: bool = false,

                    fn onConnected(ctx: ?*anyopaque, _: BtHci.Link) void {
                        const self: *@This() = @ptrCast(@alignCast(ctx.?));
                        self.connected = true;
                    }
                };

                var mock = try Mock.init(lib.testing.allocator, .{});
                defer mock.deinit();

                const hci = mock.asHci();

                var central_state = CentralState{};
                hci.setCentralListener(.{
                    .ctx = &central_state,
                    .on_adv_report = CentralState.onAdv,
                    .on_connected = CentralState.onConnected,
                    .on_disconnected = CentralState.onDisconnected,
                });

                try hci.retain();
                defer hci.release();

                try hci.startScanning(.{});
                try lib.testing.expect(central_state.saw_adv);

                try hci.connect(mock.getPeerAddr(), .public, .{});
                try lib.testing.expect(central_state.connected);
                try lib.testing.expect(hci.getLink(.central) != null);

                hci.disconnect(mock.config.conn_handle, 0x13);
                try lib.testing.expect(central_state.disconnected);
                try lib.testing.expect(hci.getLink(.central) == null);

                var peripheral_state = PeripheralState{};
                hci.setPeripheralListener(.{
                    .ctx = &peripheral_state,
                    .on_connected = PeripheralState.onConnected,
                });

                try hci.startAdvertising(.{
                    .connectable = true,
                });
                try mock.connectAsCentral();
                try lib.testing.expect(peripheral_state.connected);
                try lib.testing.expect(hci.getLink(.peripheral) != null);
            }

            {
                var central = try Mock.init(lib.testing.allocator, .{});
                defer central.deinit();

                var peripheral = try Mock.init(lib.testing.allocator, .{
                    .controller_addr = .{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 },
                    .peer_addr = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                });
                defer peripheral.deinit();

                try peripheral.asHci().startAdvertising(.{ .connectable = true });
                try central.establishPeerLink(&peripheral);

                var params: [3]u8 = undefined;
                lib.mem.writeInt(u16, params[0..2], central.config.conn_handle, .little);
                params[2] = @intFromEnum(hci_status.remote_user_terminated);

                var cmd_buf: [hci_commands.MAX_CMD_LEN]u8 = undefined;
                _ = try central.write(hci_commands.encode(&cmd_buf, hci_commands.DISCONNECT, &params));

                try lib.testing.expect(central.asHci().getLink(.central) == null);
                try lib.testing.expect(peripheral.asHci().getLink(.peripheral) == null);

                var evt_buf: [80]u8 = undefined;
                const evt_len = try peripheral.read(&evt_buf);
                const event = hci_events.decode(evt_buf[0..evt_len]) orelse return error.NoEvent;
                switch (event) {
                    .disconnection_complete => {},
                    else => return error.ExpectedDisconnectionComplete,
                }
            }

            {
                var mock = try Mock.init(lib.testing.allocator, .{
                    .recv_timeout_ms = null,
                });
                defer mock.deinit();

                var buf: [8]u8 = undefined;
                try lib.testing.expectError(error.Timeout, mock.read(&buf));
            }
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

