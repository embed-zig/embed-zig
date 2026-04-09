//! In-process loopback smoke: memory `Transport` with canned modem replies + `Peer.exchange`.
//!
//! No hardware. For **host + device firmware** over USB-UART, see
//! [`integration/dte_serial_host.zig`](../integration/dte_serial_host.zig) (POSIX; wired from `test_runner/integration.zig`).

const Peer = @import("../../Peer.zig");
const Transport = @import("../../Transport.zig");
const testing_api = @import("testing");

const buf_size = 2048;

pub fn Loopback() type {
    return struct {
        const Self = @This();

        up: [buf_size]u8 = undefined,
        up_len: usize = 0,
        down: [buf_size]u8 = undefined,
        down_len: usize = 0,
        down_read: usize = 0,
        read_deadline_ns: ?i64 = null,
        write_deadline_ns: ?i64 = null,

        pub fn init() Self {
            return .{};
        }

        pub fn write(self: *Self, data: []const u8) Transport.WriteError!usize {
            if (self.up_len + data.len > self.up.len) return error.Unexpected;
            @memcpy(self.up[self.up_len..][0..data.len], data);
            self.up_len += data.len;
            self.pumpCompleteLines() catch return error.Unexpected;
            return data.len;
        }

        pub fn read(self: *Self, out: []u8) Transport.ReadError!usize {
            self.pumpCompleteLines() catch return error.Unexpected;
            if (self.down_read >= self.down_len) return 0;
            const avail = self.down_len - self.down_read;
            const n = @min(out.len, avail);
            @memcpy(out[0..n], self.down[self.down_read..][0..n]);
            self.down_read += n;
            if (self.down_read >= self.down_len) {
                self.down_read = 0;
                self.down_len = 0;
            }
            return n;
        }

        pub fn flushRx(self: *Self) void {
            self.down_read = 0;
            self.down_len = 0;
        }

        pub fn reset(self: *Self) void {
            self.up_len = 0;
            self.down_len = 0;
            self.down_read = 0;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn setReadDeadline(self: *Self, deadline_ns: ?i64) void {
            self.read_deadline_ns = deadline_ns;
        }

        pub fn setWriteDeadline(self: *Self, deadline_ns: ?i64) void {
            self.write_deadline_ns = deadline_ns;
        }

        fn pumpCompleteLines(self: *Self) error{Unexpected}!void {
            while (true) {
                const rel = findCrlfLine(self.up[0..self.up_len]) orelse break;
                const body = trimAscii(self.up[0..rel.start]);
                const consumed = rel.end;
                shiftLeft(&self.up, &self.up_len, consumed);

                if (body.len == 0) continue;

                var chunk: [512]u8 = undefined;
                const n = demoRespond(body, &chunk) catch |err| switch (err) {
                    error.OutTooSmall, error.NoMatch => return error.Unexpected,
                };
                if (self.down_len + n > self.down.len) return error.Unexpected;
                @memcpy(self.down[self.down_len..][0..n], chunk[0..n]);
                self.down_len += n;
            }
        }
    };
}

const CrlfLine = struct { start: usize, end: usize };

fn findCrlfLine(buf: []const u8) ?CrlfLine {
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n') {
            return .{ .start = i, .end = i + 2 };
        }
    }
    return null;
}

fn trimAscii(slice: []const u8) []const u8 {
    var s: usize = 0;
    var e = slice.len;
    while (s < e and (slice[s] == ' ' or slice[s] == '\t')) s += 1;
    while (e > s and (slice[e - 1] == ' ' or slice[e - 1] == '\t')) e -= 1;
    return slice[s..e];
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (haystack[i] != prefix[i]) return false;
    }
    return true;
}

fn shiftLeft(buf: []u8, len: *usize, n: usize) void {
    if (n >= len.*) {
        len.* = 0;
        return;
    }
    const rest = len.* - n;
    var i: usize = 0;
    while (i < rest) : (i += 1) buf[i] = buf[n + i];
    len.* = rest;
}

/// Canned replies for **`AT`** / **`AT+…`** lines (longer prefixes first).
fn demoRespond(line: []const u8, out: []u8) error{ OutTooSmall, NoMatch }!usize {
    const t = trimAscii(line);
    if (startsWith(t, "AT+CSQ")) {
        const msg = "+CSQ: 99,99\r\nOK\r\n";
        if (out.len < msg.len) return error.OutTooSmall;
        @memcpy(out[0..msg.len], msg);
        return msg.len;
    }
    if (startsWith(t, "AT")) {
        const msg = "OK\r\n";
        if (out.len < msg.len) return error.OutTooSmall;
        @memcpy(out[0..msg.len], msg);
        return msg.len;
    }
    return error.NoMatch;
}

/// Runs the loopback `Transport` with two `Peer.exchange` calls (`AT`, then `AT+CSQ`).
pub fn runSurface(comptime lib: type) !void {
    var lb = Loopback().init();
    const transport = Transport.init(&lb);
    const P = Peer.make(lib);
    var peer = P.init(.{ .wire = transport });

    const fin1 = try peer.exchange("AT", .{});
    if (fin1 != .ok) return error.LoopbackAtFailed;

    const fin2 = try peer.exchange("AT+CSQ", .{});
    if (fin2 != .ok) return error.LoopbackCsqFailed;
}

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runSurface(lib) catch |err| {
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
