//! host.client.Conn — connected peer handle plus characteristic lookup.

const bt = @import("../../../bt.zig");

pub fn Conn(comptime lib: type, comptime ClientType: type, comptime CharacteristicType: type) type {
    _ = lib;

    return struct {
        client: *ClientType,
        info: bt.Central.ConnectionInfo,

        const Self = @This();

        pub fn disconnect(self: *Self) void {
            self.client.disconnectConn(self.info.conn_handle);
        }

        pub fn characteristic(self: *Self, service_uuid: u16, characteristic_uuid: u16) ClientType.GattError!CharacteristicType {
            const desc = try self.client.resolveCharacteristic(self.info.conn_handle, service_uuid, characteristic_uuid);
            return CharacteristicType.init(self.client, self.info.conn_handle, service_uuid, characteristic_uuid, desc);
        }

        pub fn connHandle(self: *const Self) u16 {
            return self.info.conn_handle;
        }

        pub fn peerAddr(self: *const Self) bt.Central.BdAddr {
            return self.info.peer_addr;
        }

        pub fn getInfo(self: *const Self) bt.Central.ConnectionInfo {
            return self.info;
        }
    };
}
