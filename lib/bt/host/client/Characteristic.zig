//! host.client.Characteristic — resolved characteristic bound to one connection.

const bt = @import("../../../bt.zig");
const xfer = @import("../xfer/client.zig");

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
            return xfer.write(self, data);
        }

        pub fn readX(self: *Self, allocator: lib.mem.Allocator) ![]u8 {
            return xfer.read(self, allocator);
        }

        pub fn get(self: *Self, topic: xfer.Topic, allocator: lib.mem.Allocator) ![]u8 {
            return xfer.get(self, topic, allocator);
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
    };
}
