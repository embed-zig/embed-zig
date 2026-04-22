//! host.client.Characteristic — resolved characteristic bound to one connection.

const att = @import("../att.zig");
const bt = @import("../../../bt.zig");
const xfer = @import("../xfer.zig");

pub fn Characteristic(comptime lib: type, comptime ClientType: type, comptime SubscriptionType: type) type {
    return struct {
        client: *ClientType,
        conn_handle: u16,
        service_uuid: u16,
        characteristic_uuid: u16,
        decl_handle: u16,
        value_handle: u16,
        cccd_handle: u16,
        properties: u8,

        const Self = @This();
        const PROP_READ: u8 = 0x02;
        const PROP_WRITE_NO_RESP: u8 = 0x04;
        const PROP_WRITE: u8 = 0x08;
        const PROP_NOTIFY: u8 = 0x10;
        const PROP_INDICATE: u8 = 0x20;
        const default_read_timeout_ms: u32 = 1_000;
        const default_read_max_retries: u8 = 5;
        const default_write_timeout_ms: u32 = 5_000;
        const default_send_redundancy: u8 = 3;
        const control_write_max_attempts: u32 = 3;
        const control_write_retry_delay_ns: u64 = 1_000_000;
        const ReadTx = struct {
            characteristic: *Self,
            subscription: SubscriptionType,

            const Transport = @This();

            pub fn init(characteristic: *Self) !Transport {
                return .{
                    .characteristic = characteristic,
                    .subscription = try characteristic.subscribe(),
                };
            }

            pub fn read(self: *Transport, timeout_ms: u32, out: []u8) !usize {
                const notif = self.subscription.next(timeout_ms) catch |err| switch (err) {
                    error.TimedOut => return error.Timeout,
                    else => return err,
                } orelse return error.Closed;

                const payload = notif.payload();
                if (payload.len > out.len) return error.NoSpaceLeft;
                @memcpy(out[0..payload.len], payload);
                return payload.len;
            }

            pub fn write(self: *Transport, data: []const u8) !usize {
                try self.characteristic.writeControl(data);
                return data.len;
            }

            pub fn deinit(self: *Transport) void {
                self.subscription.deinit();
            }
        };
        const WriteTx = struct {
            characteristic: *Self,
            subscription: SubscriptionType,

            const Transport = @This();

            pub fn init(characteristic: *Self) !Transport {
                return .{
                    .characteristic = characteristic,
                    .subscription = try characteristic.subscribe(),
                };
            }

            pub fn read(self: *Transport, timeout_ms: u32, out: []u8) anyerror!usize {
                const notif = (try self.subscription.next(timeout_ms)) orelse return error.Closed;
                const payload = notif.payload();
                if (payload.len > out.len) return error.NoSpaceLeft;
                @memcpy(out[0..payload.len], payload);
                return payload.len;
            }

            pub fn write(self: *Transport, payload: []const u8) !usize {
                try self.characteristic.writeControl(payload);
                return payload.len;
            }

            pub fn writeNoResp(self: *Transport, payload: []const u8) !usize {
                self.characteristic.writeNoResp(payload) catch |err| switch (err) {
                    error.AttError => try self.characteristic.write(payload),
                    else => return err,
                };
                return payload.len;
            }

            pub fn deinit(self: *Transport) void {
                self.subscription.deinit();
            }
        };

        pub fn init(client: *ClientType, conn_handle: u16, service_uuid: u16, characteristic_uuid: u16, desc: bt.Central.DiscoveredChar) Self {
            return .{
                .client = client,
                .conn_handle = conn_handle,
                .service_uuid = service_uuid,
                .characteristic_uuid = characteristic_uuid,
                .decl_handle = desc.decl_handle,
                .value_handle = desc.value_handle,
                .cccd_handle = desc.cccd_handle,
                .properties = desc.properties,
            };
        }

        pub fn read(self: *Self, out: []u8) ClientType.GattError!usize {
            if (!self.hasRead()) return error.AttError;
            return self.client.readAttr(self.conn_handle, self.value_handle, out);
        }

        pub fn write(self: *Self, data: []const u8) ClientType.GattError!void {
            if (!self.hasWrite()) return error.AttError;
            return self.client.writeAttr(self.conn_handle, self.value_handle, data);
        }

        pub fn writeNoResp(self: *Self, data: []const u8) ClientType.GattError!void {
            if (!self.hasWriteNoResp()) return error.AttError;
            return self.client.writeAttrNoResp(self.conn_handle, self.value_handle, data);
        }

        pub fn attMtu(self: *Self) u16 {
            return self.client.attMtu(self.conn_handle);
        }

        pub fn writeX(self: *Self, data: []const u8) !void {
            var transport = try WriteTx.init(self);
            const mtu = effectiveMtu(self);
            return xfer.write(lib, self.client.allocator, &transport, data, .{
                .att_mtu = mtu,
                .timeout_ms = default_write_timeout_ms,
                .send_redundancy = default_send_redundancy,
            });
        }

        pub fn readX(self: *Self, allocator: lib.mem.Allocator) ![]u8 {
            var transport = try ReadTx.init(self);
            const mtu = effectiveMtu(self);
            return xfer.read(lib, allocator, &transport, .{
                .att_mtu = mtu,
                .timeout_ms = default_read_timeout_ms,
                .max_timeout_retries = default_read_max_retries,
            }) catch |err| switch (err) {
                error.Closed => return error.SubscriptionClosed,
                else => return err,
            };
        }

        pub fn subscribe(self: *Self) ClientType.GattError!SubscriptionType {
            if (self.cccd_handle == 0) return error.AttError;
            if (self.hasNotify()) {
                return self.client.subscribeAttr(self.conn_handle, self.value_handle, self.cccd_handle, false);
            }
            if (self.hasIndicate()) {
                return self.client.subscribeAttr(self.conn_handle, self.value_handle, self.cccd_handle, true);
            }
            return error.AttError;
        }

        pub fn hasRead(self: *const Self) bool {
            return (self.properties & PROP_READ) != 0;
        }

        pub fn hasWrite(self: *const Self) bool {
            return (self.properties & PROP_WRITE) != 0;
        }

        pub fn hasWriteNoResp(self: *const Self) bool {
            return (self.properties & PROP_WRITE_NO_RESP) != 0;
        }

        pub fn hasNotify(self: *const Self) bool {
            return (self.properties & PROP_NOTIFY) != 0;
        }

        pub fn hasIndicate(self: *const Self) bool {
            return (self.properties & PROP_INDICATE) != 0;
        }

        fn effectiveMtu(self: *Self) u16 {
            const raw_mtu = self.attMtu();
            if (raw_mtu < att.DEFAULT_MTU) return att.DEFAULT_MTU;
            return @min(raw_mtu, @as(u16, @intCast(xfer.Chunk.max_mtu)));
        }

        // xfer control packets (`read_start`, `write_start`, loss lists, ACKs) are
        // idempotent and can safely tolerate one noisy ATT write round-trip.
        fn writeControl(self: *Self, data: []const u8) ClientType.GattError!void {
            var attempt: u32 = 0;
            while (attempt < control_write_max_attempts) : (attempt += 1) {
                self.write(data) catch |err| switch (err) {
                    error.AttError, error.Timeout => {
                        if (attempt + 1 < control_write_max_attempts) {
                            lib.Thread.sleep(control_write_retry_delay_ns);
                            continue;
                        }
                        return err;
                    },
                    else => return err,
                };
                return;
            }
        }
    };
}
