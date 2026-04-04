//! xfer.send — shared server-side send loop shape.
//!
//! The concrete transport is supplied by the caller and must provide one
//! bidirectional session surface plus address identity:
//! - `read(timeout_ms, out)` to wait for one inbound request/control packet
//! - `write(data)` to emit control packets such as the write start marker
//! - `writeNoResp(data)` to emit one outbound data chunk without response
//! - `deinit()` to release session resources
//! - `connHandle()`, `serviceUuid()`, and `charUuid()` for handler context

const embed = @import("embed");
const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");
const write_xfer = @import("write.zig");

pub const Config = struct {
    att_mtu: u16 = att.DEFAULT_MTU,
    timeout_ms: u32 = 5_000,
    send_redundancy: u8 = 3,
    max_timeout_retries: u8 = 5,
};

pub const DataFn = *const fn (
    allocator: embed.mem.Allocator,
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    start: Chunk.ReadStartMetadata,
) anyerror![]u8;

pub fn send(
    comptime lib: type,
    allocator: embed.mem.Allocator,
    transport: anytype,
    dataFn: DataFn,
    config: Config,
) !void {
    const TransportPtr = @TypeOf(transport);
    const Transport = switch (@typeInfo(TransportPtr)) {
        .pointer => |ptr| ptr.child,
        else => @compileError("xfer.send expects a transport pointer"),
    };

    comptime {
        _ = @as(*const fn (*Transport) u16, &Transport.connHandle);
        _ = @as(*const fn (*Transport) u16, &Transport.serviceUuid);
        _ = @as(*const fn (*Transport) u16, &Transport.charUuid);
        _ = @as(*const fn (*Transport, u32, []u8) anyerror!usize, &Transport.read);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.write);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.writeNoResp);
        _ = @as(*const fn (*Transport) void, &Transport.deinit);
    }

    const ReplyTx = struct {
        inner: TransportPtr,

        pub fn read(self: *@This(), timeout_ms: u32, out: []u8) anyerror!usize {
            while (true) {
                const len = try self.inner.read(timeout_ms, out);
                if (Chunk.isReadStartMagic(out[0..len])) continue;
                return len;
            }
        }

        pub fn write(self: *@This(), data: []const u8) anyerror!usize {
            if (Chunk.isWriteStartMagic(data)) return data.len;
            return self.inner.write(data);
        }

        pub fn writeNoResp(self: *@This(), data: []const u8) anyerror!usize {
            return self.inner.writeNoResp(data);
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }
    };

    var handed_off = false;
    errdefer if (!handed_off) transport.deinit();

    var req_buf: [Chunk.max_mtu]u8 = undefined;
    const req_len = try transport.read(config.timeout_ms, &req_buf);
    const req = req_buf[0..req_len];
    if (!Chunk.isReadStartMagic(req)) return error.InvalidReadStart;

    const start = try Chunk.decodeReadStartMetadata(req[Chunk.read_start_magic.len..]);
    const payload = try dataFn(
        allocator,
        transport.connHandle(),
        transport.serviceUuid(),
        transport.charUuid(),
        start,
    );
    defer if (payload.len > 0) allocator.free(payload);

    var reply_tx = ReplyTx{ .inner = transport };
    handed_off = true;
    return write_xfer.write(lib, allocator, &reply_tx, payload, .{
        .att_mtu = config.att_mtu,
        .timeout_ms = config.timeout_ms,
        .send_redundancy = config.send_redundancy,
        .max_timeout_retries = config.max_timeout_retries,
    });
}
