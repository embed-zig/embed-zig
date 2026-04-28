const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 320 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                const Thread = lib.Thread;
                const StartGate = test_utils.StartGate(lib);
                const packet_count = 128;
                const packet_len = 1024;
                const header_len = 4;

                const ReadCtx = struct {
                    gate: *StartGate,
                    conn: net.PacketConn,
                    expected_addr: net.netip.AddrPort,
                    seed: u8,
                    seen: []bool,
                    err: ?anyerror = null,
                };

                const WriteCtx = struct {
                    gate: *StartGate,
                    conn: net.PacketConn,
                    dest: net.netip.AddrPort,
                    seed: u8,
                    err: ?anyerror = null,
                };

                fn call(a: lib.mem.Allocator) !void {
                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            var buf: [packet_len]u8 = undefined;
                            ctx.gate.wait();
                            for (0..packet_count) |_| {
                                const result = ctx.conn.readFrom(&buf) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                                verifyPacket(ctx, result, &buf) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                            }
                        }

                        fn write(ctx: *WriteCtx) void {
                            var buf: [packet_len]u8 = undefined;
                            ctx.gate.wait();
                            for (0..packet_count) |seq| {
                                encodePacket(&buf, @intCast(seq), ctx.seed);
                                const n = ctx.conn.writeTo(&buf, ctx.dest) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                                if (n != buf.len) {
                                    ctx.err = error.ShortWrite;
                                    return;
                                }
                                if (seq % 8 == 7) Thread.sleep(lib.time.ns_per_ms);
                            }
                        }
                    };

                    var a_pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer a_pc.deinit();
                    var b_pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer b_pc.deinit();

                    a_pc.setReadTimeout(10_000);
                    a_pc.setWriteTimeout(10_000);
                    b_pc.setReadTimeout(10_000);
                    b_pc.setWriteTimeout(10_000);

                    const a_impl = try a_pc.as(net.UdpConn);
                    const b_impl = try b_pc.as(net.UdpConn);
                    const a_addr = try a_impl.localAddr();
                    const b_addr = try b_impl.localAddr();

                    var a_seen = [_]bool{false} ** packet_count;
                    var b_seen = [_]bool{false} ** packet_count;
                    var gate = StartGate.init(4);

                    var a_reader = ReadCtx{
                        .gate = &gate,
                        .conn = a_pc,
                        .expected_addr = b_addr,
                        .seed = 0x91,
                        .seen = a_seen[0..],
                    };
                    var a_writer = WriteCtx{
                        .gate = &gate,
                        .conn = a_pc,
                        .dest = b_addr,
                        .seed = 0x33,
                    };
                    var b_reader = ReadCtx{
                        .gate = &gate,
                        .conn = b_pc,
                        .expected_addr = a_addr,
                        .seed = 0x33,
                        .seen = b_seen[0..],
                    };
                    var b_writer = WriteCtx{
                        .gate = &gate,
                        .conn = b_pc,
                        .dest = a_addr,
                        .seed = 0x91,
                    };

                    var a_reader_thread = try Thread.spawn(.{}, Worker.read, .{&a_reader});
                    var a_writer_thread = try Thread.spawn(.{}, Worker.write, .{&a_writer});
                    var b_reader_thread = try Thread.spawn(.{}, Worker.read, .{&b_reader});
                    var b_writer_thread = try Thread.spawn(.{}, Worker.write, .{&b_writer});

                    a_reader_thread.join();
                    a_writer_thread.join();
                    b_reader_thread.join();
                    b_writer_thread.join();

                    if (a_reader.err) |err| return err;
                    if (a_writer.err) |err| return err;
                    if (b_reader.err) |err| return err;
                    if (b_writer.err) |err| return err;

                    for (a_seen) |seen| try lib.testing.expect(seen);
                    for (b_seen) |seen| try lib.testing.expect(seen);
                }

                fn verifyPacket(ctx: *ReadCtx, result: net.PacketConn.ReadFromResult, buf: *const [packet_len]u8) !void {
                    if (result.bytes_read != packet_len) return error.InvalidPacketLength;
                    try expectAddrEq(result.addr, ctx.expected_addr);

                    const seq = decodePacketSeq(buf[0..]);
                    if (seq >= packet_count) return error.InvalidPacketSequence;
                    if (ctx.seen[seq]) return error.DuplicatePacketSequence;
                    try expectPacketPayload(buf[0..], seq, ctx.seed);
                    ctx.seen[seq] = true;
                }

                fn encodePacket(buf: *[packet_len]u8, seq: u32, seed: u8) void {
                    buf[0] = @truncate(seq >> 24);
                    buf[1] = @truncate(seq >> 16);
                    buf[2] = @truncate(seq >> 8);
                    buf[3] = @truncate(seq);
                    for (buf[header_len..], 0..) |*byte, i| {
                        byte.* = @truncate((i * 131 + seq + seed) % 251);
                    }
                }

                fn decodePacketSeq(buf: []const u8) usize {
                    return (@as(usize, buf[0]) << 24) |
                        (@as(usize, buf[1]) << 16) |
                        (@as(usize, buf[2]) << 8) |
                        @as(usize, buf[3]);
                }

                fn expectPacketPayload(buf: []const u8, seq: usize, seed: u8) !void {
                    for (buf[header_len..], 0..) |byte, i| {
                        const expected: u8 = @truncate((i * 131 + seq + seed) % 251);
                        if (byte != expected) return error.InvalidPacketPayload;
                    }
                }

                fn expectAddrEq(actual: net.netip.AddrPort, expected: net.netip.AddrPort) !void {
                    try lib.testing.expectEqual(expected.port(), actual.port());
                    try lib.testing.expect(net.netip.Addr.compare(expected.addr(), actual.addr()) == .eq);
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
