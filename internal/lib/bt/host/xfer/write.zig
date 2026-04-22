//! xfer.write — shared write-side transfer loop shape.
//!
//! This file defines the top-level function shape for a shared xfer write loop.
//! The concrete transport is supplied by the caller and must provide one
//! bidirectional session surface:
//! - `read(timeout_ms, out)` to wait for one inbound control packet
//! - `write(data)` to emit control packets such as the write start marker
//! - `writeNoResp(data)` to emit one outbound data chunk without response
//! - `deinit()` to release session resources

const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");
const testing_api = @import("testing");

pub const Config = struct {
    att_mtu: u16 = att.DEFAULT_MTU,
    timeout_ms: u32 = 5_000,
    send_redundancy: u8 = 3,
    max_timeout_retries: u8 = 5,
};

pub fn write(comptime lib: type, allocator: lib.mem.Allocator, transport: anytype, data: []const u8, config: Config) !void {
    const TransportPtr = @TypeOf(transport);
    const Transport = switch (@typeInfo(TransportPtr)) {
        .pointer => |ptr| ptr.child,
        else => @compileError("xfer.write expects a transport pointer"),
    };

    comptime {
        _ = @as(*const fn (*Transport, u32, []u8) anyerror!usize, &Transport.read);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.write);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.writeNoResp);
        _ = @as(*const fn (*Transport) void, &Transport.deinit);
    }

    defer transport.deinit();
    _ = allocator;

    if (data.len == 0) return error.EmptyData;

    const mtu = config.att_mtu;
    const dcs = Chunk.dataChunkSize(mtu);
    const total_usize = Chunk.chunksNeeded(data.len, mtu);
    if (total_usize > Chunk.max_chunks) return error.TooManyChunks;
    const total: u16 = @intCast(total_usize);

    const mask_len = Chunk.Bitmask.requiredBytes(total);
    var sndmask: [Chunk.max_mask_bytes]u8 = undefined;
    Chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var resp_buf: [Chunk.max_mtu]u8 = undefined;
    var timeout_count: u8 = 0;
    _ = try transport.write(&Chunk.write_start_magic);

    while (true) {
        try sendMarkedChunks(transport, data, sndmask[0..mask_len], total, dcs, config.send_redundancy);

        const resp_len = transport.read(config.timeout_ms, &resp_buf) catch |err| switch (err) {
            error.Timeout => {
                timeout_count += 1;
                if (timeout_count >= config.max_timeout_retries) return error.Timeout;
                _ = try transport.write(&Chunk.write_start_magic);
                continue;
            },
            else => return err,
        };
        timeout_count = 0;
        const payload = resp_buf[0..resp_len];

        if (Chunk.isAck(payload)) return;

        Chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = Chunk.decodeLossList(payload, &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;

        var accepted_loss = false;
        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) {
                Chunk.Bitmask.set(sndmask[0..mask_len], seq);
                accepted_loss = true;
            }
        }
        if (!accepted_loss) return error.InvalidResponse;
    }
}

fn sendMarkedChunks(
    transport: anytype,
    data: []const u8,
    sndmask: []const u8,
    total: u16,
    dcs: usize,
    send_redundancy: u8,
) !void {
    var chunk_buf: [Chunk.max_mtu]u8 = undefined;
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        const seq: u16 = i + 1;
        if (!Chunk.Bitmask.isSet(sndmask, seq)) continue;

        const hdr = (Chunk.Header{ .total = total, .seq = seq }).encode();
        @memcpy(chunk_buf[0..Chunk.header_size], &hdr);

        const offset: usize = @as(usize, i) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        @memcpy(
            chunk_buf[Chunk.header_size .. Chunk.header_size + payload_len],
            data[offset .. offset + payload_len],
        );

        const total_len = Chunk.header_size + payload_len;
        for (0..send_redundancy) |_| {
            _ = try transport.writeNoResp(chunk_buf[0..total_len]);
        }
    }
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const AckTransport = struct {
                start_writes: usize = 0,
                chunk_seqs: [8]u16 = [_]u16{0} ** 8,
                chunk_count: usize = 0,
                deinited: bool = false,
                ack_sent: bool = false,

                pub fn read(self: *@This(), _: u32, out: []u8) anyerror!usize {
                    if (self.ack_sent) return error.Closed;
                    self.ack_sent = true;
                    @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
                    return Chunk.ack_signal.len;
                }
                pub fn write(self: *@This(), data: []const u8) !usize {
                    try lib.testing.expectEqualSlices(u8, &Chunk.write_start_magic, data);
                    self.start_writes += 1;
                    return data.len;
                }
                pub fn writeNoResp(self: *@This(), data: []const u8) !usize {
                    const hdr = Chunk.Header.decode(data[0..Chunk.header_size]);
                    self.chunk_seqs[self.chunk_count] = hdr.seq;
                    self.chunk_count += 1;
                    return data.len;
                }
                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            var payload_data: [20]u8 = undefined;
            @memset(&payload_data, 0xAB);
            var ack_transport = AckTransport{};
            try write(lib, lib.testing.allocator, &ack_transport, &payload_data, .{ .send_redundancy = 1 });
            try lib.testing.expectEqual(@as(usize, 1), ack_transport.start_writes);
            try lib.testing.expectEqual(@as(usize, 2), ack_transport.chunk_count);
            try lib.testing.expectEqualSlices(u16, &.{ 1, 2 }, ack_transport.chunk_seqs[0..ack_transport.chunk_count]);
            try lib.testing.expect(ack_transport.deinited);

            const RetryTransport = struct {
                step_index: usize = 0,
                chunk_seqs: [8]u16 = [_]u16{0} ** 8,
                chunk_count: usize = 0,
                deinited: bool = false,

                pub fn read(self: *@This(), _: u32, out: []u8) anyerror!usize {
                    const step = self.step_index;
                    self.step_index += 1;
                    switch (step) {
                        0 => {
                            const encoded = Chunk.encodeLossList(&.{2}, out);
                            return encoded.len;
                        },
                        1 => {
                            @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
                            return Chunk.ack_signal.len;
                        },
                        else => return error.Closed,
                    }
                }
                pub fn write(_: *@This(), bytes: []const u8) !usize {
                    return bytes.len;
                }
                pub fn writeNoResp(self: *@This(), bytes: []const u8) !usize {
                    const hdr = Chunk.Header.decode(bytes[0..Chunk.header_size]);
                    self.chunk_seqs[self.chunk_count] = hdr.seq;
                    self.chunk_count += 1;
                    return bytes.len;
                }
                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            @memset(&payload_data, 0xCD);
            var retry_transport = RetryTransport{};
            try write(lib, lib.testing.allocator, &retry_transport, &payload_data, .{ .send_redundancy = 1 });
            try lib.testing.expectEqual(@as(usize, 3), retry_transport.chunk_count);
            try lib.testing.expectEqualSlices(u16, &.{ 1, 2, 2 }, retry_transport.chunk_seqs[0..retry_transport.chunk_count]);
            try lib.testing.expect(retry_transport.deinited);

            const TimeoutTransport = struct {
                read_count: usize = 0,
                start_writes: usize = 0,
                chunk_count: usize = 0,
                deinited: bool = false,

                pub fn read(self: *@This(), _: u32, out: []u8) anyerror!usize {
                    switch (self.read_count) {
                        0 => {
                            self.read_count += 1;
                            return error.Timeout;
                        },
                        1 => {
                            self.read_count += 1;
                            @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
                            return Chunk.ack_signal.len;
                        },
                        else => return error.Closed,
                    }
                }
                pub fn write(self: *@This(), bytes: []const u8) !usize {
                    try lib.testing.expectEqualSlices(u8, &Chunk.write_start_magic, bytes);
                    self.start_writes += 1;
                    return bytes.len;
                }
                pub fn writeNoResp(self: *@This(), _: []const u8) !usize {
                    self.chunk_count += 1;
                    return 1;
                }
                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            @memset(&payload_data, 0xEF);
            var timeout_transport = TimeoutTransport{};
            try write(lib, lib.testing.allocator, &timeout_transport, &payload_data, .{ .send_redundancy = 1 });
            try lib.testing.expectEqual(@as(usize, 2), timeout_transport.start_writes);
            try lib.testing.expectEqual(@as(usize, 4), timeout_transport.chunk_count);
            try lib.testing.expect(timeout_transport.deinited);

            const InvalidLossTransport = struct {
                read_count: usize = 0,
                deinited: bool = false,

                pub fn read(self: *@This(), _: u32, out: []u8) anyerror!usize {
                    if (self.read_count != 0) return error.Closed;
                    self.read_count += 1;
                    const encoded = Chunk.encodeLossList(&.{999}, out);
                    return encoded.len;
                }
                pub fn write(_: *@This(), bytes: []const u8) !usize {
                    return bytes.len;
                }
                pub fn writeNoResp(_: *@This(), bytes: []const u8) !usize {
                    return bytes.len;
                }
                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            @memset(&payload_data, 0xAA);
            var invalid_transport = InvalidLossTransport{};
            try lib.testing.expectError(
                error.InvalidResponse,
                write(lib, lib.testing.allocator, &invalid_transport, &payload_data, .{ .send_redundancy = 1 }),
            );
            try lib.testing.expect(invalid_transport.deinited);
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

