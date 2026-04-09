//! **Peer** — AT-style **framing** and **I/O** over [`Transport`](Transport.zig).
//!
//! **TX and RX are independent** (USB/UART full-duplex): **`writeRaw`** / **`exchange`** outbound
//! writes do not block the RX path; **`readLine`** / **`wire.read`** / URC handling are separate
//! incremental reads on the same byte stream. **URCs** (device → host, no reply) are just
//! lines you get via **`readLine`** or non-terminal lines inside **`exchange`** (`on_info_line`).
//! Chunked raw reads: set deadline on **`wire`** then **`wire.read`** (see **`Config.transport_read_timeout_ms`**).
//!
//! **DTE:** **`exchange`** sends a command, then reads lines until **`OK`** / **`ERROR`** / …
//! **DCE:** **`readLine`** then **`writeRaw`** your reply. Same type on both ends.
//!
//! Field **`wire`** is the [`Transport`](Transport.zig) handle (`transport` is a Zig keyword).
//! For **fixed-length** raw reads (e.g. after parsing `+QHTTPREAD: <len>`), set deadlines on
//! **`wire`** and loop **`wire.read`** yourself — **`Peer`** does not wrap **`readExact`**.

const LineReaderMod = @import("LineReader.zig");
const Transport = @import("Transport.zig");

/// Max **one AT text line** (body + terminator while assembling in [`LineReader`](LineReader.zig)),
/// same role as **`wifi.max_ssid_len`** / HCI **`MAX_*`** caps — tune only if your modem sends longer lines.
pub const max_line_len: usize = 256;

/// Build a peer for injected `lib` using [`max_line_len`].
pub fn make(comptime lib: type) type {
    comptime {
        _ = lib.time.milliTimestamp;
    }

    const LineReader = LineReaderMod.LineReader(max_line_len);

    return struct {
        const Self = @This();

        wire: Transport,
        reader: LineReader = LineReader.init(),
        config: Config = .{},

        last_cmd_len: usize = 0,
        last_cmd: [max_line_len]u8 = undefined,

        /// When set via [`initFromBackend`], the implementation pointer behind `wire.ptr`.
        backend: ?*anyopaque = null,

        pub const ReadLineOptions = LineReader.ReadLineOptions;

        pub const Config = struct {
            transport_read_timeout_ms: u32 = 100,
            transport_write_timeout_ms: u32 = 200,
            /// Wall-clock budget for the whole `exchange` (all lines until final).
            command_timeout_ms: u32 = 10_000,
            /// If true, `exchange` appends **`\r\n`** after `cmd` before writing. **Outbound**
            /// only (see `LineReader` for inbound line ends). **V.250** command terminator is **S3**
            /// (default **CR**); **27.007** often uses **CRLF** on UART/USB — default `true` matches
            /// many modems; set `false` if `cmd` already ends with terminators or the DCE expects CR only.
            append_crlf: bool = true,
        };

        pub const Final = enum {
            ok,
            error_,
            cme_error,
            cms_error,
        };

        pub const ExchangeOptions = struct {
            max_non_terminal_lines: usize = 256,
            line_read: ReadLineOptions = .{},
            info_ctx: ?*anyopaque = null,
            on_info_line: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
        };

        pub const ExchangeError = Transport.WriteError || LineReaderMod.ReadLineError || error{
            Timeout,
            TooManyNonTerminalLines,
            CmdTooLong,
        };

        pub const ReadLineError = LineReaderMod.ReadLineError;

        pub const RawReadError = Transport.ReadError || error{
            RawBufferFull,
            PendingOverflow,
        };

        pub fn init(init_transport: Transport, config: Config) Self {
            return .{
                .wire = init_transport,
                .config = config,
                .backend = null,
            };
        }

        pub fn initFromBackend(backend: anytype, config: Config) Self {
            const init_transport = Transport.init(backend);
            return initWithBackend(backend, init_transport, config);
        }

        pub fn backendAs(self: *Self, comptime T: type) ?*T {
            const p = self.backend orelse return null;
            return @ptrCast(@alignCast(p));
        }

        pub fn clearReader(self: *Self) void {
            self.reader.clear();
        }

        pub fn flushRx(self: *Self) void {
            self.wire.flushRx();
        }

        pub fn writeRaw(self: *Self, data: []const u8) Transport.WriteError!void {
            try self.transportWriteAll(data);
        }

        pub fn readUntilByte(self: *Self, out: []u8, term: u8) RawReadError![]const u8 {
            var total: usize = 0;
            while (true) {
                if (total >= out.len) return error.RawBufferFull;
                self.wire.setReadDeadline(ioDeadlineNs(self.config.transport_read_timeout_ms));
                const n = try self.wire.read(out[total..]);
                if (n == 0) continue;
                const chunk = out[total..][0..n];
                if (lib.mem.indexOfScalar(u8, chunk, term)) |rel| {
                    const after = chunk[rel + 1 ..];
                    if (after.len > 0) {
                        self.reader.appendPending(after) catch return error.PendingOverflow;
                    }
                    return out[0 .. total + rel];
                }
                total += n;
            }
        }

        pub fn readLine(self: *Self, out: []u8, line_read: ReadLineOptions) ReadLineError![]const u8 {
            self.wire.setReadDeadline(ioDeadlineNs(self.config.transport_read_timeout_ms));
            return self.reader.readLine(self.wire, out, line_read);
        }

        /// Send `cmd`, then read lines until a **final** result. Clears the line assembler and
        /// **`flushRx`** first. Non-terminal lines (URC / info) invoke `on_info_line` if set.
        pub fn exchange(self: *Self, cmd: []const u8, ex: ExchangeOptions) ExchangeError!Final {
            self.reader.clear();
            self.wire.flushRx();

            if (cmd.len > max_line_len) return error.CmdTooLong;
            @memcpy(self.last_cmd[0..cmd.len], cmd);
            self.last_cmd_len = cmd.len;

            var send_buf: [max_line_len + 2]u8 = undefined;
            const to_send: []const u8 = blk: {
                if (self.config.append_crlf) {
                    if (cmd.len + 2 > send_buf.len) return error.CmdTooLong;
                    @memcpy(send_buf[0..cmd.len], cmd);
                    send_buf[cmd.len] = '\r';
                    send_buf[cmd.len + 1] = '\n';
                    break :blk send_buf[0 .. cmd.len + 2];
                }
                @memcpy(send_buf[0..cmd.len], cmd);
                break :blk send_buf[0..cmd.len];
            };
            try self.transportWriteAll(to_send);

            const exchange_end_ns = lib.time.milliTimestamp() * 1_000_000 +
                @as(i64, self.config.command_timeout_ms) * 1_000_000;

            var non_term: usize = 0;
            var line_buf: [max_line_len]u8 = undefined;

            while (true) {
                if (lib.time.milliTimestamp() * 1_000_000 > exchange_end_ns) {
                    return error.Timeout;
                }
                self.wire.setReadDeadline(ioDeadlineNs(self.config.transport_read_timeout_ms));
                const line = try self.reader.readLine(self.wire, &line_buf, ex.line_read);

                const body = trimAscii(line);
                if (self.last_cmd_len > 0 and
                    body.len == self.last_cmd_len and
                    lib.mem.eql(u8, body, self.last_cmd[0..self.last_cmd_len]))
                {
                    continue;
                }

                if (classifyFinal(body)) |fin| return fin;

                if (non_term >= ex.max_non_terminal_lines) return error.TooManyNonTerminalLines;
                non_term += 1;
                if (ex.on_info_line) |cb| {
                    cb(ex.info_ctx, line);
                }
            }
        }

        fn initWithBackend(backend: anytype, init_transport: Transport, config: Config) Self {
            return .{
                .wire = init_transport,
                .config = config,
                .backend = @ptrCast(@alignCast(backend)),
            };
        }

        fn classifyFinal(body: []const u8) ?Final {
            if (lib.mem.eql(u8, body, "OK")) return .ok;
            if (lib.mem.eql(u8, body, "ERROR")) return .error_;
            if (lib.mem.startsWith(u8, body, "+CME ERROR:")) return .cme_error;
            if (lib.mem.startsWith(u8, body, "+CMS ERROR:")) return .cms_error;
            return null;
        }

        fn trimAscii(slice: []const u8) []const u8 {
            var s: usize = 0;
            var e = slice.len;
            while (s < e and (slice[s] == ' ' or slice[s] == '\t')) s += 1;
            while (e > s and (slice[e - 1] == ' ' or slice[e - 1] == '\t')) e -= 1;
            return slice[s..e];
        }

        fn ioDeadlineNs(timeout_ms: u32) i64 {
            return lib.time.milliTimestamp() * 1_000_000 + @as(i64, timeout_ms) * 1_000_000;
        }

        fn transportWriteAll(self: *Self, buf: []const u8) Transport.WriteError!void {
            var off: usize = 0;
            while (off < buf.len) {
                self.wire.setWriteDeadline(ioDeadlineNs(self.config.transport_write_timeout_ms));
                const n = try self.wire.write(buf[off..]);
                if (n == 0) return error.Unexpected;
                off += n;
            }
        }
    };
}

const testing_api = @import("testing");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testReadLineInbound() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), _: []const u8) Transport.WriteError!usize {
                    return 0;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "AT+CSQ\r\n" };
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{ .append_crlf = false });
            var buf: [64]u8 = undefined;
            const line = try peer.readLine(&buf, .{});
            try testing.expectEqualStrings("AT+CSQ", line);
        }

        fn testExchangeFailsOnTransportReadTimeout() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                pub fn read(_: *@This(), _: []u8) Transport.ReadError!usize {
                    return error.Timeout;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{};
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{ .append_crlf = false });
            const r = peer.exchange("AT", .{});
            try testing.expectError(error.Timeout, r);
        }

        fn testExchangeCmdTooLong() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                pub fn read(_: *@This(), _: []u8) Transport.ReadError!usize {
                    return 0;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{};
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{ .append_crlf = false });
            var too_long: [max_line_len + 1]u8 = undefined;
            @memset(&too_long, 'X');
            const r = peer.exchange(&too_long, .{});
            try testing.expectError(error.CmdTooLong, r);
        }

        fn testInitFromBackendTransportAndBackendAs() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                marker: u32 = 0xbeef_cafe,
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "OK\r\n" };
            const P = make(Lib);
            var peer = P.initFromBackend(&back, .{ .append_crlf = false });
            try testing.expectEqual(peer.wire.ptr, @as(*anyopaque, @ptrCast(&back)));
            const impl = peer.backendAs(Impl).?;
            try testing.expectEqual(@as(u32, 0xbeef_cafe), impl.marker);

            const fin = try peer.exchange("AT", .{});
            try testing.expectEqual(P.Final.ok, fin);
        }

        fn testExchangeOkAfterInfo() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "+CSQ: 99,99\r\nOK\r\n" };
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{ .append_crlf = false });

            var infos: usize = 0;
            const Cb = struct {
                fn on(ctx: ?*anyopaque, _: []const u8) void {
                    const c: *usize = @ptrCast(@alignCast(ctx.?));
                    c.* += 1;
                }
            };

            const fin = try peer.exchange("AT+CSQ", .{
                .info_ctx = @ptrCast(&infos),
                .on_info_line = Cb.on,
            });
            try testing.expectEqual(P.Final.ok, fin);
            try testing.expectEqual(@as(usize, 1), infos);
        }

        fn testStripEcho() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "AT+CSQ\r\n+CSQ: 1\r\nOK\r\n" };
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{ .append_crlf = false });

            const fin = try peer.exchange("AT+CSQ", .{});
            try testing.expectEqual(P.Final.ok, fin);
        }

        fn testReadUntilByteInjectsTrailingLine() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), _: []const u8) Transport.WriteError!usize {
                    return 0;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "hello\x1AOK\r\n" };
            const transport = Transport.init(&back);
            const P = make(Lib);
            var peer = P.init(transport, .{});

            var raw: [16]u8 = undefined;
            const pdu = try peer.readUntilByte(&raw, 0x1a);
            try testing.expectEqualStrings("hello", pdu);

            var line_buf: [16]u8 = undefined;
            const line = try peer.readLine(&line_buf, .{});
            try testing.expectEqualStrings("OK", line);
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

            inline for (.{
                TestCase.testReadLineInbound,
                TestCase.testExchangeFailsOnTransportReadTimeout,
                TestCase.testExchangeCmdTooLong,
                TestCase.testInitFromBackendTransportAndBackendAs,
                TestCase.testExchangeOkAfterInfo,
                TestCase.testStripEcho,
                TestCase.testReadUntilByteInjectsTrailingLine,
            }) |f| {
                f() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
