//! LineReader — incremental byte stream → one text line at a time (AT on-the-wire framing).
//!
//! **Spec basis:** ITU-T **V.250** (Hayes-style): the command line is terminated by the
//! character in **S3** (default **CR**, ASCII 13). DCE responses often use **CR+LF** in
//! practice—the same **CRLF** sequence that ends each **HTTP/1.x** header line (text
//! protocol framing, not AT semantics).
//!
//! This type only finds **line boundaries**; it does not parse `OK`, `ERROR`, or URCs
//! (that stays in `Session`).

const Transport = @import("Transport.zig");

pub fn LineReader(comptime cap: usize) type {
    return struct {
        const Self = @This();

        pending: [cap]u8 = undefined,
        pending_len: usize = 0,

        pub const ReadLineOptions = struct {
            /// Trim ASCII space (`0x20`) and tab (`0x09`) at both ends after removing
            /// the line terminator.
            trim_spaces: bool = false,
        };

        pub fn init() Self {
            return .{};
        }

        /// Drop buffered partial line (e.g. after `Transport.flushRx`).
        pub fn clear(self: *Self) void {
            self.pending_len = 0;
        }

        /// Read from `transport` until one full line is available, copy the line body
        /// into `out` (without the terminator), and return that slice.
        ///
        /// **Terminator rules** (first match wins, scan left to right):
        /// - **`\\n`**: line is the bytes before it; a single trailing **`\\r`** on that
        ///   span is stripped (so `...\\r\\n` yields the same body as HTTP-style CRLF).
        /// - **`\\r`** with another byte following: line is the bytes before **`\\r`**.
        ///   If the next byte is **`\\n`**, both are consumed; otherwise only **`\\r`**
        ///   is consumed (V.250-style **CR-only** line end when LF is not used).
        /// - **`\\r`** as the **last** byte in `pending`: treated as **incomplete** until
        ///   more data arrives (so a split **`\\r`/`\\n`** across reads does not become two
        ///   lines). A lone **`\\r`** with no further bytes is therefore not emitted here;
        ///   upper layers should bound reads with `Transport` deadlines or EOF policy.
        ///
        /// If `cap` bytes are buffered without completing a line, returns
        /// `error.LineTooLong`. If the line body does not fit in `out`, returns
        /// `error.OutTooSmall`.
        ///
        /// If `read` returns `0` repeatedly while the line is incomplete, this loops
        /// forever — use read deadlines or a blocking backend in `Session` / `Dte`.
        pub fn readLine(
            self: *Self,
            transport: Transport,
            out: []u8,
            options: ReadLineOptions,
        ) ReadLineError![]const u8 {
            var scratch: [64]u8 = undefined;
            while (true) {
                if (try self.tryPopLineInto(out, options)) |line| {
                    return line;
                }
                if (self.pending_len >= cap) {
                    return error.LineTooLong;
                }
                const space = cap - self.pending_len;
                const to_read = @min(scratch.len, space);
                const n = try transport.read(scratch[0..to_read]);
                if (n == 0) continue;
                @memcpy(self.pending[self.pending_len..][0..n], scratch[0..n]);
                self.pending_len += n;
            }
        }

        /// If `pending` already holds at least one complete line, copy it into `out`
        /// and return the slice. Otherwise return `null` (no I/O).
        pub fn tryPopLineInto(
            self: *Self,
            out: []u8,
            options: ReadLineOptions,
        ) ReadLineError!?[]const u8 {
            const buf = self.pending[0..self.pending_len];
            const hit = scanFirstLine(buf) orelse return null;
            var raw = hit.raw;
            raw = if (options.trim_spaces) trimAsciiSpaces(raw) else raw;
            if (raw.len > out.len) return error.OutTooSmall;
            @memcpy(out[0..raw.len], raw);
            const rest = self.pending_len - hit.consumed;
            shiftPendingLeft(self.pending[0..], hit.consumed, self.pending_len);
            self.pending_len = rest;
            return out[0..raw.len];
        }

        /// First complete line in `buf`: body slice (no terminator) and total prefix
        /// length to remove including terminators.
        fn scanFirstLine(buf: []const u8) ?struct { raw: []const u8, consumed: usize } {
            var i: usize = 0;
            while (i < buf.len) : (i += 1) {
                switch (buf[i]) {
                    '\n' => {
                        var raw = buf[0..i];
                        if (raw.len > 0 and raw[raw.len - 1] == '\r')
                            raw = raw[0 .. raw.len - 1];
                        return .{ .raw = raw, .consumed = i + 1 };
                    },
                    '\r' => {
                        if (i + 1 < buf.len) {
                            const raw = buf[0..i];
                            const consumed: usize = if (buf[i + 1] == '\n') i + 2 else i + 1;
                            return .{ .raw = raw, .consumed = consumed };
                        }
                        return null;
                    },
                    else => {},
                }
            }
            return null;
        }

        fn trimAsciiSpaces(slice: []const u8) []const u8 {
            var s: usize = 0;
            var e = slice.len;
            while (s < e and (slice[s] == ' ' or slice[s] == '\t')) s += 1;
            while (e > s and (slice[e - 1] == ' ' or slice[e - 1] == '\t')) e -= 1;
            return slice[s..e];
        }

        /// `buf[0..total_len]` valid; move suffix after `consumed` to front (overlap-safe).
        fn shiftPendingLeft(buf: []u8, consumed: usize, total_len: usize) void {
            const rest = total_len - consumed;
            if (rest == 0 or consumed == 0) return;
            var i: usize = 0;
            while (i < rest) : (i += 1) {
                buf[i] = buf[consumed + i];
            }
        }
    };
}

pub const ReadLineError = Transport.ReadError || error{
    LineTooLong,
    OutTooSmall,
};

test "at/unit_tests/LineReader/crlf_single_chunk" {
    const std = @import("std");
    const testing = std.testing;

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

    var back = Impl{ .data = "OK\r\n" };
    const transport = Transport.init(&back);
    var reader = LineReader(64).init();
    var out: [16]u8 = undefined;
    const line = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("OK", line);
}

test "at/unit_tests/LineReader/cr_only_when_not_followed_by_lf" {
    const std = @import("std");
    const testing = std.testing;

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

    var back = Impl{ .data = "OK\r+" };
    const transport = Transport.init(&back);
    var reader = LineReader(64).init();
    var out: [16]u8 = undefined;
    const line = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("OK", line);
    // `+` has no terminator yet; remainder stays in `pending` (no infinite read).
    try testing.expectEqual(@as(usize, 1), reader.pending_len);
    try testing.expectEqual(@as(u8, '+'), reader.pending[0]);
}

test "at/unit_tests/LineReader/split_cr_lf_across_reads" {
    const std = @import("std");
    const testing = std.testing;

    const Impl = struct {
        chunks: []const []const u8,
        idx: usize = 0,
        pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
            if (self.idx >= self.chunks.len) return 0;
            const chunk = self.chunks[self.idx];
            self.idx += 1;
            const n = @min(buf.len, chunk.len);
            @memcpy(buf[0..n], chunk[0..n]);
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

    var back = Impl{ .chunks = &.{ "AT\r", "\n+CSQ: 1\r\n" } };
    const transport = Transport.init(&back);
    var reader = LineReader(64).init();
    var out: [32]u8 = undefined;
    const l1 = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("AT", l1);
    const l2 = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("+CSQ: 1", l2);
}

test "at/unit_tests/LineReader/lf_only_line" {
    const std = @import("std");
    const testing = std.testing;

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

    var back = Impl{ .data = "hello\n" };
    const transport = Transport.init(&back);
    var reader = LineReader(64).init();
    var out: [16]u8 = undefined;
    const line = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("hello", line);
}

test "at/unit_tests/LineReader/trim_spaces_and_clear" {
    const std = @import("std");
    const testing = std.testing;

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

    var back = Impl{ .data = "  hi  \r\n" };
    const transport = Transport.init(&back);
    var reader = LineReader(64).init();
    var out: [16]u8 = undefined;
    const line = try reader.readLine(transport, &out, .{ .trim_spaces = true });
    try testing.expectEqualStrings("hi", line);

    reader.clear();
    back = Impl{ .data = "x\n" };
    const line2 = try reader.readLine(transport, &out, .{});
    try testing.expectEqualStrings("x", line2);
}

test "at/unit_tests/LineReader/line_too_long" {
    const std = @import("std");
    const testing = std.testing;

    const Impl = struct {
        pub fn read(_: *@This(), buf: []u8) Transport.ReadError!usize {
            @memset(buf[0..1], 'a');
            return 1;
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

    var back = Impl{};
    const transport = Transport.init(&back);
    var reader = LineReader(8).init();
    var out: [16]u8 = undefined;
    try testing.expectError(error.LineTooLong, reader.readLine(transport, &out, .{}));
}

test "at/unit_tests/LineReader/out_too_small" {
    const std = @import("std");
    const testing = std.testing;

    const Impl = struct {
        pub fn read(_: *@This(), _: []u8) Transport.ReadError!usize {
            return 0;
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

    var back = Impl{};
    _ = Transport.init(&back);
    var reader = LineReader(64).init();
    reader.pending[0..5].* = "hello".*;
    reader.pending[5] = '\n';
    reader.pending_len = 6;
    var out: [2]u8 = undefined;
    try testing.expectError(error.OutTooSmall, reader.tryPopLineInto(&out, .{}));
}
