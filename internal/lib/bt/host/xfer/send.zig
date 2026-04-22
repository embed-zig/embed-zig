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
const testing_api = @import("testing");
const write_xfer = @import("write.zig");

pub const Config = struct {
    att_mtu: u16 = att.DEFAULT_MTU,
    timeout_ms: u32 = 5_000,
    send_redundancy: u8 = 3,
    max_timeout_retries: u8 = 5,
};

pub const DataFn = *const fn (
    ctx: ?*anyopaque,
    allocator: embed.mem.Allocator,
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
) anyerror![]u8;

pub fn send(
    comptime lib: type,
    allocator: embed.mem.Allocator,
    transport: anytype,
    data_ctx: ?*anyopaque,
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
    if (!Chunk.isReadStartMagic(req) or req.len != Chunk.read_start_magic.len) return error.InvalidReadStart;
    const payload = try dataFn(
        data_ctx,
        allocator,
        transport.connHandle(),
        transport.serviceUuid(),
        transport.charUuid(),
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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const invalid_read_start = [_]u8{ 0xFF, 0xFF, 0x00, 0x03 };
            const oversized_read_start = [_]u8{ 0xFF, 0xFF, 0x00, 0x01, 0xAA };

            const InvalidStartTransport = struct {
                deinited: bool = false,

                pub fn connHandle(_: *@This()) u16 {
                    return 0x0042;
                }

                pub fn serviceUuid(_: *@This()) u16 {
                    return 0x180D;
                }

                pub fn charUuid(_: *@This()) u16 {
                    return 0x2A58;
                }

                pub fn read(_: *@This(), _: u32, out: []u8) anyerror!usize {
                    @memcpy(out[0..invalid_read_start.len], &invalid_read_start);
                    return invalid_read_start.len;
                }

                pub fn write(_: *@This(), data: []const u8) anyerror!usize {
                    return data.len;
                }

                pub fn writeNoResp(_: *@This(), data: []const u8) anyerror!usize {
                    return data.len;
                }

                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            var invalid_transport = InvalidStartTransport{};
            try lib.testing.expectError(error.InvalidReadStart, send(
                lib,
                lib.testing.allocator,
                &invalid_transport,
                null,
                struct {
                    fn dataFn(_: ?*anyopaque, _: embed.mem.Allocator, _: u16, _: u16, _: u16) ![]u8 {
                        return error.ShouldNotRun;
                    }
                }.dataFn,
                .{},
            ));
            try lib.testing.expect(invalid_transport.deinited);

            const OversizedStartTransport = struct {
                deinited: bool = false,

                pub fn connHandle(_: *@This()) u16 {
                    return 0x0042;
                }

                pub fn serviceUuid(_: *@This()) u16 {
                    return 0x180D;
                }

                pub fn charUuid(_: *@This()) u16 {
                    return 0x2A58;
                }

                pub fn read(_: *@This(), _: u32, out: []u8) anyerror!usize {
                    @memcpy(out[0..oversized_read_start.len], &oversized_read_start);
                    return oversized_read_start.len;
                }

                pub fn write(_: *@This(), data: []const u8) anyerror!usize {
                    return data.len;
                }

                pub fn writeNoResp(_: *@This(), data: []const u8) anyerror!usize {
                    return data.len;
                }

                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            var oversized_transport = OversizedStartTransport{};
            try lib.testing.expectError(error.InvalidReadStart, send(
                lib,
                lib.testing.allocator,
                &oversized_transport,
                null,
                struct {
                    fn dataFn(_: ?*anyopaque, _: embed.mem.Allocator, _: u16, _: u16, _: u16) ![]u8 {
                        return error.ShouldNotRun;
                    }
                }.dataFn,
                .{},
            ));
            try lib.testing.expect(oversized_transport.deinited);

            const EmptyPayloadTransport = struct {
                write_count: usize = 0,
                deinited: bool = false,

                pub fn connHandle(_: *@This()) u16 {
                    return 0x0042;
                }

                pub fn serviceUuid(_: *@This()) u16 {
                    return 0x180D;
                }

                pub fn charUuid(_: *@This()) u16 {
                    return 0x2A58;
                }

                pub fn read(_: *@This(), _: u32, out: []u8) anyerror!usize {
                    @memcpy(out[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
                    return Chunk.read_start_magic.len;
                }

                pub fn write(self: *@This(), data: []const u8) anyerror!usize {
                    self.write_count += 1;
                    return data.len;
                }

                pub fn writeNoResp(_: *@This(), data: []const u8) anyerror!usize {
                    return data.len;
                }

                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            var empty_transport = EmptyPayloadTransport{};
            try lib.testing.expectError(error.EmptyData, send(
                lib,
                lib.testing.allocator,
                &empty_transport,
                null,
                struct {
                    fn dataFn(_: ?*anyopaque, _: embed.mem.Allocator, _: u16, _: u16, _: u16) ![]u8 {
                        return &.{};
                    }
                }.dataFn,
                .{},
            ));
            try lib.testing.expectEqual(@as(usize, 0), empty_transport.write_count);
            try lib.testing.expect(empty_transport.deinited);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
