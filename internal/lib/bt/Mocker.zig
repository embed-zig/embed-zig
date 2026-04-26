//! Mocker — multi-node Bluetooth simulation world.
//!
//! Owns multiple `mocker.Hci` instances and creates real `bt.Host`
//! bundles on top. Nodes can discover each other, connect by address, and
//! carry a 3D position for future spatial simulation.

const glib = @import("glib");

const root = @import("../bt.zig");
const host_mod = @import("Host.zig");
const Hci = @import("mocker/Hci.zig").Hci;

pub fn Mocker(comptime lib: type, comptime Channel: fn (type) type) type {
    const HciImpl = Hci(lib);
    const HostCtor = host_mod.makeHci(lib, Channel);

    return struct {
        const Self = @This();

        pub const Vec3 = struct {
            x: f32 = 0,
            y: f32 = 0,
            z: f32 = 0,
        };

        pub const Config = struct {
            max_discovery_distance_m: ?f32 = null,
            base_rssi: i8 = -42,
            rssi_loss_per_meter: f32 = 2.0,
        };

        pub const CreateHostConfig = struct {
            position: Vec3 = .{},
            hci: HciImpl.Config = .{},
            host: HostCtor.Config = .{ .allocator = undefined },
        };

        const Node = struct {
            impl: *HciImpl,
            position: Vec3,
        };

        allocator: lib.mem.Allocator,
        config: Config,
        mutex: lib.Thread.Mutex = .{},
        nodes: glib.std.ArrayListUnmanaged(Node) = .{},

        pub fn init(allocator: lib.mem.Allocator, config: Config) Self {
            return .{
                .allocator = allocator,
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.nodes.items) |node| {
                node.impl.deinit();
                self.allocator.destroy(node.impl);
            }
            self.nodes.deinit(self.allocator);
        }

        pub fn createHost(self: *Self, config: CreateHostConfig) !root.Host {
            const ptr = try self.createHciNode(.{
                .position = config.position,
                .hci = config.hci,
            });
            errdefer self.destroyHciNode(ptr);

            var host_config = config.host;
            host_config.allocator = self.allocator;
            return try HostCtor.init(ptr.asHci(), host_config);
        }

        const CreateHciNodeConfig = struct {
            position: Vec3 = .{},
            hci: HciImpl.Config = .{},
        };

        fn createHciNode(self: *Self, config: CreateHciNodeConfig) !*HciImpl {
            const ptr = try self.allocator.create(HciImpl);
            errdefer self.allocator.destroy(ptr);
            ptr.* = try HciImpl.init(self.allocator, config.hci);
            errdefer ptr.deinit();

            ptr.setWorldHooks(.{
                .ctx = self,
                .on_scan_started = onScanStarted,
                .on_adv_state_changed = onAdvStateChanged,
                .on_connect_requested = onConnectRequested,
            });

            self.mutex.lock();
            defer self.mutex.unlock();
            try self.nodes.append(self.allocator, .{
                .impl = ptr,
                .position = config.position,
            });

            return ptr;
        }

        fn destroyHciNode(self: *Self, ptr: *HciImpl) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const index = self.indexOf(ptr) orelse return;
            const node = self.nodes.orderedRemove(index);
            node.impl.deinit();
            self.allocator.destroy(node.impl);
        }

        fn indexOf(self: *Self, ptr: *HciImpl) ?usize {
            for (self.nodes.items, 0..) |node, i| {
                if (node.impl == ptr) return i;
            }
            return null;
        }

        fn onScanStarted(ctx: ?*anyopaque, scanner: *HciImpl, _: root.Hci.ScanConfig) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.nodes.items) |node| {
                if (node.impl == scanner) continue;
                if (!node.impl.isAdvertisingNode()) continue;
                if (!self.canDiscover(scanner, node.impl)) continue;
                scanner.fireCentralAdvReportFrom(node.impl, self.rssiBetween(scanner, node.impl));
            }
        }

        fn onAdvStateChanged(ctx: ?*anyopaque, advertiser: *HciImpl, enabled: bool) void {
            if (!enabled) return;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.nodes.items) |node| {
                if (node.impl == advertiser) continue;
                if (!node.impl.isScanningNode()) continue;
                if (!self.canDiscover(node.impl, advertiser)) continue;
                node.impl.fireCentralAdvReportFrom(advertiser, self.rssiBetween(node.impl, advertiser));
            }
        }

        fn onConnectRequested(
            ctx: ?*anyopaque,
            requester: *HciImpl,
            addr: root.Hci.BdAddr,
            addr_type: root.Hci.AddrType,
            _: root.Hci.ConnConfig,
        ) root.Hci.Error!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            const peer = self.findNodeByAddr(addr, addr_type) orelse return error.Rejected;
            if (peer == requester) return error.Rejected;
            if (!peer.isAdvertisingNode()) return error.Rejected;
            if (!self.canDiscover(requester, peer)) return error.Rejected;
            try requester.establishPeerLink(peer);
        }

        fn findNodeByAddr(self: *Self, addr: root.Hci.BdAddr, addr_type: root.Hci.AddrType) ?*HciImpl {
            for (self.nodes.items) |node| {
                if (node.impl.controllerAddrType() != addr_type) continue;
                if (glib.std.mem.eql(u8, &node.impl.controllerAddr(), &addr)) return node.impl;
            }
            return null;
        }

        fn canDiscover(self: *Self, a: *HciImpl, b: *HciImpl) bool {
            const limit = self.config.max_discovery_distance_m orelse return true;
            return self.distanceBetween(a, b) <= limit;
        }

        fn rssiBetween(self: *Self, a: *HciImpl, b: *HciImpl) i8 {
            const d = self.distanceBetween(a, b);
            const raw = @as(f32, @floatFromInt(self.config.base_rssi)) - d * self.config.rssi_loss_per_meter;
            const clamped = @max(-127.0, @min(20.0, raw));
            return @intFromFloat(clamped);
        }

        fn distanceBetween(self: *Self, a: *HciImpl, b: *HciImpl) f32 {
            const pa = self.positionOf(a) orelse Vec3{};
            const pb = self.positionOf(b) orelse Vec3{};
            const dx = pa.x - pb.x;
            const dy = pa.y - pb.y;
            const dz = pa.z - pb.z;
            return @sqrt(dx * dx + dy * dy + dz * dz);
        }

        fn positionOf(self: *Self, hci: *HciImpl) ?Vec3 {
            for (self.nodes.items) |node| {
                if (node.impl == hci) return node.position;
            }
            return null;
        }
    };
}
