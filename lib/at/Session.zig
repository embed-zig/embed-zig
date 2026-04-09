//! Session — one AT **exchange** (command → lines until final result) over `Transport` + `LineReader`.
//!
//! Handles **timeouts**, **command-echo skipping** when a line matches the last sent **`cmd`**
//! (ATE1-style), and **non-terminal lines** (info / URC) via callback. For **prompts (`>`), raw PDU, length-prefixed binary**, use `writeRaw` / `readExact`
//! and `clearReader` / `flushRx` between line-mode phases (see `lib/at/README.md`).

const Transport = @import("Transport.zig");
const LineReaderMod = @import("LineReader.zig");

pub fn make(comptime lib: type, comptime line_cap: usize) type {
    const LineReader = LineReaderMod.LineReader(line_cap);

    return struct {
        const Self = @This();

        transport: Transport,
        reader: LineReader = LineReader.init(),
        config: Config = .{},

        last_cmd_len: usize = 0,
        last_cmd: [line_cap]u8 = undefined,

        pub const Config = struct {
            transport_read_timeout_ms: u32 = 100,
            transport_write_timeout_ms: u32 = 200,
            /// Wall-clock budget for the whole `exchange` (all lines until final).
            command_timeout_ms: u32 = 10_000,
            /// If true, `exchange` appends **`\r\n`** after `cmd` before writing. **Outbound**
            /// only (see `LineReader` for inbound line ends).
            ///
            /// ITU-T **V.250** defines the command-line terminator via **S3** (default **CR**).
            /// **3GPP TS 27.007** builds on that framing; **CRLF** is not the only legal form,
            /// but is widely used on UART/USB and matches many modem manuals — hence default `true`.
            /// Set `false` when `cmd` already includes terminators or the DCE expects **CR only**
            /// (per datasheet / `ATS3`).
            append_crlf: bool = true,
        };

        /// Result of `exchange` when the modem returns a **final** result line (after ASCII trim).
        pub const Final = enum {
            /// Line **`OK`** (27.007-style success).
            ok,
            /// Line **`ERROR`** — generic failure; no **`+CME` / `+CMS`** detail on that line.
            error_,
            /// Line starts with **`+CME ERROR:`** — **C**ME = mobile **E**quipment / network-side
            /// extended errors in **3GPP TS 27.007** (numeric or verbose text after the colon).
            cme_error,
            /// Line starts with **`+CMS ERROR:`** — **SMS** service failures in **3GPP TS 27.005**
            /// (send/read/delete SMS and related commands).
            cms_error,
        };

        pub const ExchangeOptions = struct {
            max_non_terminal_lines: usize = 256,
            line_read: LineReader.ReadLineOptions = .{},
            info_ctx: ?*anyopaque = null,
            on_info_line: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
        };

        pub const ExchangeError = Transport.WriteError || LineReaderMod.ReadLineError || error{
            Timeout,
            TooManyNonTerminalLines,
            CmdTooLong,
        };

        pub fn init(transport: Transport, config: Config) Self {
            return .{
                .transport = transport,
                .config = config,
            };
        }

        pub fn flushRx(self: *Self) void {
            self.transport.flushRx();
        }

        pub fn clearReader(self: *Self) void {
            self.reader.clear();
        }

        /// Write bytes with per-chunk write deadline (e.g. raw PDU after `>` prompt).
        pub fn writeRaw(self: *Self, data: []const u8) Transport.WriteError!void {
            try self.transportWriteAll(data);
        }

        /// Read exactly `buf.len` bytes with a fresh read deadline on each `transport.read`.
        pub fn readExact(self: *Self, buf: []u8) Transport.ReadError!void {
            var filled: usize = 0;
            while (filled < buf.len) {
                self.transport.setReadDeadline(ioDeadlineNs(self.config.transport_read_timeout_ms));
                const n = try self.transport.read(buf[filled..]);
                if (n == 0) continue;
                filled += n;
            }
        }

        /// Send `cmd`, then read lines until a **final** result (`OK`, `ERROR`, `+CME ERROR:`,
        /// `+CMS ERROR:`). Non-terminal lines invoke `on_info_line` if set.
        ///
        /// **Timeouts:** `command_timeout_ms` caps the whole exchange; each `readLine` call uses
        /// `transport_read_timeout_ms` once at entry (see README if a line trickles in slowly).
        pub fn exchange(self: *Self, cmd: []const u8, ex: ExchangeOptions) ExchangeError!Final {
            if (cmd.len > line_cap) return error.CmdTooLong;
            @memcpy(self.last_cmd[0..cmd.len], cmd);
            self.last_cmd_len = cmd.len;

            var send_buf: [line_cap + 2]u8 = undefined;
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
            var line_buf: [line_cap]u8 = undefined;

            while (true) {
                if (lib.time.milliTimestamp() * 1_000_000 > exchange_end_ns) {
                    return error.Timeout;
                }
                self.transport.setReadDeadline(ioDeadlineNs(self.config.transport_read_timeout_ms));
                const line = try self.reader.readLine(self.transport, &line_buf, ex.line_read);

                const body = trimAscii(line);
                // ATE1 (and similar) echoes the command line before the result. Skip that line so
                // it does not count toward max_non_terminal_lines or fire on_info_line. Match is
                // against the last exchange() cmd body only (trimmed ASCII); if echo formatting
                // differs, use ATE0 or handle outside exchange.
                if (self.last_cmd_len > 0 and
                    body.len == self.last_cmd_len and
                    lib.mem.eql(u8, body, self.last_cmd[0..self.last_cmd_len]))
                {
                    continue;
                }

                if (classifyFinal(lib, body)) |fin| return fin;

                if (non_term >= ex.max_non_terminal_lines) return error.TooManyNonTerminalLines;
                non_term += 1;
                if (ex.on_info_line) |cb| {
                    cb(ex.info_ctx, line);
                }
            }
        }

        /// `body` must already be ASCII-trimmed (same as `exchange` uses after `readLine`).
        fn classifyFinal(mem_lib: type, body: []const u8) ?Final {
            if (mem_lib.mem.eql(u8, body, "OK")) return .ok;
            if (mem_lib.mem.eql(u8, body, "ERROR")) return .error_;
            if (mem_lib.mem.startsWith(u8, body, "+CME ERROR:")) return .cme_error;
            if (mem_lib.mem.startsWith(u8, body, "+CMS ERROR:")) return .cms_error;
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
                self.transport.setWriteDeadline(ioDeadlineNs(self.config.transport_write_timeout_ms));
                const n = try self.transport.write(buf[off..]);
                if (n == 0) return error.Unexpected;
                off += n;
            }
        }
    };
}

const testing_api = @import("testing");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
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
            const S = make(Lib, 64);
            var session = S.init(transport, .{ .append_crlf = false });

            var infos: usize = 0;
            const Cb = struct {
                fn on(ctx: ?*anyopaque, _: []const u8) void {
                    const c: *usize = @ptrCast(@alignCast(ctx.?));
                    c.* += 1;
                }
            };

            const fin = try session.exchange("AT+CSQ", .{
                .info_ctx = @ptrCast(&infos),
                .on_info_line = Cb.on,
            });
            try testing.expectEqual(S.Final.ok, fin);
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
            const S = make(Lib, 64);
            var session = S.init(transport, .{ .append_crlf = false });

            const fin = try session.exchange("AT+CSQ", .{});
            try testing.expectEqual(S.Final.ok, fin);
        }

        fn testReadExact() !void {
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

            var back = Impl{ .data = "\x01\x02\x03\x04" };
            const transport = Transport.init(&back);
            const S = make(Lib, 32);
            var session = S.init(transport, .{});

            var buf: [4]u8 = undefined;
            try session.readExact(&buf);
            try testing.expectEqual(@as(u8, 0x04), buf[3]);
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

            TestCase.testExchangeOkAfterInfo() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testStripEcho() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testReadExact() catch |err| {
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
