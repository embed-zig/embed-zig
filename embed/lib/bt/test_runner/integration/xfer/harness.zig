const glib = @import("glib");
const Chunk = @import("../../../host/xfer.zig").Chunk;

pub const test_conn_handle: u16 = 0x0042;
pub const test_service_uuid: u16 = 0x180D;
pub const test_char_uuid: u16 = 0x2A37;

pub fn make(comptime grt: type) type {
    const ByteChannel = grt.sync.Channel([]u8);

    return struct {
        allocator: glib.std.mem.Allocator,
        left_to_right: ByteChannel,
        right_to_left: ByteChannel,

        const Self = @This();

        pub const Endpoint = struct {
            allocator: glib.std.mem.Allocator,
            inbound: *ByteChannel,
            outbound: *ByteChannel,
            drop_seq_once: ?u16 = null,
            dropped: bool = false,

            pub fn read(self: *@This(), timeout: glib.time.duration.Duration, out: []u8) !usize {
                const recv_res = try self.inbound.recvTimeout(timeout);
                if (!recv_res.ok) return error.Closed;

                const payload = recv_res.value;
                defer self.allocator.free(payload);

                if (payload.len > out.len) return error.NoSpaceLeft;
                @memcpy(out[0..payload.len], payload);
                return payload.len;
            }

            pub fn write(self: *@This(), data: []const u8) !usize {
                try self.sendImpl(data);
                return data.len;
            }

            pub fn writeNoResp(self: *@This(), data: []const u8) !usize {
                try self.sendImpl(data);
                return data.len;
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }

            pub fn connHandle(self: *@This()) u16 {
                _ = self;
                return test_conn_handle;
            }

            pub fn serviceUuid(self: *@This()) u16 {
                _ = self;
                return test_service_uuid;
            }

            pub fn charUuid(self: *@This()) u16 {
                _ = self;
                return test_char_uuid;
            }

            fn sendImpl(self: *@This(), data: []const u8) !void {
                if (self.shouldDrop(data)) return;

                const copy = try self.allocator.dupe(u8, data);
                errdefer self.allocator.free(copy);

                const send_res = try self.outbound.send(copy);
                if (!send_res.ok) return error.Closed;
            }

            fn shouldDrop(self: *@This(), data: []const u8) bool {
                const seq = self.drop_seq_once orelse return false;
                if (self.dropped) return false;
                if (Chunk.isReadStartMagic(data) or Chunk.isWriteStartMagic(data) or Chunk.isAck(data)) return false;
                if (data.len < Chunk.header_size) return false;

                const hdr = Chunk.Header.decode(data[0..Chunk.header_size]);
                if (hdr.seq != seq) return false;

                self.dropped = true;
                return true;
            }
        };

        pub fn init(allocator: glib.std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .left_to_right = try ByteChannel.make(allocator, 64),
                .right_to_left = try ByteChannel.make(allocator, 64),
            };
        }

        pub fn deinit(self: *Self) void {
            self.left_to_right.close();
            self.right_to_left.close();
            drainChannel(self.allocator, &self.left_to_right);
            drainChannel(self.allocator, &self.right_to_left);
            self.left_to_right.deinit();
            self.right_to_left.deinit();
            self.* = undefined;
        }

        pub fn left(self: *Self) Endpoint {
            return .{
                .allocator = self.allocator,
                .inbound = &self.right_to_left,
                .outbound = &self.left_to_right,
            };
        }

        pub fn right(self: *Self) Endpoint {
            return .{
                .allocator = self.allocator,
                .inbound = &self.left_to_right,
                .outbound = &self.right_to_left,
            };
        }
    };
}

fn drainChannel(allocator: anytype, channel: anytype) void {
    while (true) {
        const recv_res = channel.recv() catch break;
        if (!recv_res.ok) break;
        allocator.free(recv_res.value);
    }
}

pub fn fillPattern(out: []u8, seed: u8) void {
    for (out, 0..) |*byte, i| {
        byte.* = seed +% @as(u8, @truncate(i * 17));
    }
}
