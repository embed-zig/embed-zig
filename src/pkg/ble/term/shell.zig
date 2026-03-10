//! shell — Command registry, request/response types, and cancellation.
//!
//! Provides the handler pattern for BLE Term: register named commands,
//! dispatch incoming requests, and support cooperative cancellation.
//!
//! ## Handler Pattern (Go http analogy)
//!
//! | Go HTTP              | BLE Term                          |
//! |----------------------|-----------------------------------|
//! | `http.HandlerFunc`   | `HandlerFn`                       |
//! | `http.Request`       | `Request` (cmd, id, cancel)       |
//! | `http.ResponseWriter`| `ResponseWriter` (write, print)   |
//! | URL path             | command name                      |
//!
//! ## JSON Protocol
//!
//! Request:  `{"cmd":"ls","id":1}`
//! Response: `{"id":1,"out":"...","err":"","exit":0}`

const std = @import("std");

// ============================================================================
// CancellationToken
// ============================================================================

/// Cooperative cancellation signal. Passed to handlers so they can
/// check `isCancelled()` during long-running operations.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }
};

// ============================================================================
// Request
// ============================================================================

pub const Request = struct {
    cmd: []const u8,
    args: []const u8,
    id: u32,
    conn_handle: u16,
    cancel: *const CancellationToken,
    user_ctx: ?*anyopaque,
};

// ============================================================================
// ResponseWriter
// ============================================================================

pub const ResponseWriter = struct {
    buf: []u8,
    pos: usize = 0,
    exit_code: i8 = 0,
    err_msg: []const u8 = "",

    pub fn init(buf: []u8) ResponseWriter {
        return .{ .buf = buf };
    }

    pub fn write(self: *ResponseWriter, data: []const u8) void {
        const n = @min(data.len, self.buf.len - self.pos);
        if (n > 0) {
            @memcpy(self.buf[self.pos..][0..n], data[0..n]);
            self.pos += n;
        }
    }

    pub fn print(self: *ResponseWriter, comptime fmt: []const u8, args: anytype) void {
        const remaining = self.buf[self.pos..];
        const written = std.fmt.bufPrint(remaining, fmt, args) catch |e| switch (e) {
            error.NoSpaceLeft => {
                self.pos = self.buf.len;
                return;
            },
        };
        self.pos += written.len;
    }

    pub fn setError(self: *ResponseWriter, code: i8, msg: []const u8) void {
        self.exit_code = code;
        self.err_msg = msg;
    }

    pub fn output(self: *const ResponseWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

// ============================================================================
// Handler
// ============================================================================

pub const HandlerFn = *const fn (*const Request, *ResponseWriter) void;

// ============================================================================
// Shell — Command Registry
// ============================================================================

pub const max_commands: usize = 32;
pub const max_name_len: usize = 32;

const CommandEntry = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    handler: HandlerFn = undefined,
    ctx: ?*anyopaque = null,
    active: bool = false,
};

pub const Shell = struct {
    commands: [max_commands]CommandEntry = [_]CommandEntry{.{}} ** max_commands,
    count: usize = 0,

    pub fn init() Shell {
        return .{};
    }

    pub fn register(self: *Shell, name: []const u8, handler: HandlerFn, ctx: ?*anyopaque) error{Full}!void {
        if (self.count >= max_commands) return error.Full;
        if (name.len > max_name_len) return error.Full;

        var entry = &self.commands[self.count];
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = @intCast(name.len);
        entry.handler = handler;
        entry.ctx = ctx;
        entry.active = true;
        self.count += 1;
    }

    pub fn dispatch(
        self: *const Shell,
        cmd_name: []const u8,
        args: []const u8,
        id: u32,
        conn_handle: u16,
        cancel: *const CancellationToken,
        resp_buf: []u8,
    ) ResponseWriter {
        var writer = ResponseWriter.init(resp_buf);

        for (self.commands[0..self.count]) |entry| {
            if (entry.active and entry.name_len == cmd_name.len and
                std.mem.eql(u8, entry.name[0..entry.name_len], cmd_name))
            {
                const req = Request{
                    .cmd = cmd_name,
                    .args = args,
                    .id = id,
                    .conn_handle = conn_handle,
                    .cancel = cancel,
                    .user_ctx = entry.ctx,
                };
                entry.handler(&req, &writer);
                return writer;
            }
        }

        writer.setError(1, "unknown command");
        return writer;
    }

    pub fn find(self: *const Shell, name: []const u8) ?HandlerFn {
        for (self.commands[0..self.count]) |entry| {
            if (entry.active and entry.name_len == name.len and
                std.mem.eql(u8, entry.name[0..entry.name_len], name))
            {
                return entry.handler;
            }
        }
        return null;
    }
};

// ============================================================================
// JSON Protocol — minimal encode/decode for fixed format
// ============================================================================

pub const ParsedCommand = struct {
    cmd: []const u8,
    args: []const u8,
    id: u32,
};

/// Parse `{"cmd":"ls -la","id":1}` — minimal parser for the fixed protocol.
/// cmd field may contain args separated by space.
pub fn parseRequest(data: []const u8) ?ParsedCommand {
    const cmd_str = extractString(data, "cmd") orelse return null;
    const id = extractU32(data, "id") orelse return null;

    // Split cmd into command name and args at first space
    var cmd_name = cmd_str;
    var args: []const u8 = "";
    if (std.mem.indexOfScalar(u8, cmd_str, ' ')) |sp| {
        cmd_name = cmd_str[0..sp];
        args = cmd_str[sp + 1 ..];
    }

    return .{ .cmd = cmd_name, .args = args, .id = id };
}

/// Encode response JSON into buf. Returns written slice.
/// Format: `{"id":N,"out":"...","err":"...","exit":N}`
pub fn encodeResponse(buf: []u8, id: u32, out: []const u8, err_msg: []const u8, exit_code: i8) []const u8 {
    var pos: usize = 0;

    pos += copyTo(buf[pos..], "{\"id\":");
    pos += fmtU32(buf[pos..], id);
    pos += copyTo(buf[pos..], ",\"out\":\"");
    pos += escapeJson(buf[pos..], out);
    pos += copyTo(buf[pos..], "\",\"err\":\"");
    pos += escapeJson(buf[pos..], err_msg);
    pos += copyTo(buf[pos..], "\",\"exit\":");
    if (exit_code < 0) {
        if (pos < buf.len) {
            buf[pos] = '-';
            pos += 1;
        }
        pos += fmtU32(buf[pos..], @intCast(-@as(i16, exit_code)));
    } else {
        pos += fmtU32(buf[pos..], @intCast(exit_code));
    }
    pos += copyTo(buf[pos..], "}");

    return buf[0..pos];
}

// ============================================================================
// JSON helpers (no allocator, no std.json)
// ============================================================================

fn extractString(data: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value"
    var i: usize = 0;
    while (i + key.len + 4 < data.len) : (i += 1) {
        if (data[i] == '"' and i + 1 + key.len + 1 < data.len and
            std.mem.eql(u8, data[i + 1 ..][0..key.len], key) and
            data[i + 1 + key.len] == '"')
        {
            // Found "key", now find :"value"
            var j = i + 1 + key.len + 1;
            while (j < data.len and (data[j] == ':' or data[j] == ' ')) : (j += 1) {}
            if (j < data.len and data[j] == '"') {
                j += 1;
                const start = j;
                while (j < data.len and data[j] != '"') : (j += 1) {
                    if (data[j] == '\\' and j + 1 < data.len) j += 1;
                }
                return data[start..j];
            }
        }
    }
    return null;
}

fn extractU32(data: []const u8, key: []const u8) ?u32 {
    var i: usize = 0;
    while (i + key.len + 4 < data.len) : (i += 1) {
        if (data[i] == '"' and i + 1 + key.len + 1 < data.len and
            std.mem.eql(u8, data[i + 1 ..][0..key.len], key) and
            data[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < data.len and (data[j] == ':' or data[j] == ' ')) : (j += 1) {}
            var val: u32 = 0;
            var found = false;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {
                val = val * 10 + (data[j] - '0');
                found = true;
            }
            if (found) return val;
        }
    }
    return null;
}

fn copyTo(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn fmtU32(dst: []u8, val: u32) usize {
    if (dst.len == 0) return 0;
    if (val == 0) {
        dst[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    const n = @min(len, dst.len);
    for (0..n) |idx| {
        dst[idx] = tmp[len - 1 - idx];
    }
    return n;
}

fn escapeJson(dst: []u8, src: []const u8) usize {
    var pos: usize = 0;
    for (src) |c| {
        switch (c) {
            '"' => {
                if (pos + 2 > dst.len) return pos;
                dst[pos] = '\\';
                dst[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                if (pos + 2 > dst.len) return pos;
                dst[pos] = '\\';
                dst[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                if (pos + 2 > dst.len) return pos;
                dst[pos] = '\\';
                dst[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > dst.len) return pos;
                dst[pos] = '\\';
                dst[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > dst.len) return pos;
                dst[pos] = '\\';
                dst[pos + 1] = 't';
                pos += 2;
            },
            else => {
                if (pos >= dst.len) return pos;
                dst[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

// ============================================================================
// Tests
// ============================================================================

test "CancellationToken: init not cancelled" {
    var token = CancellationToken{};
    try std.testing.expect(!token.isCancelled());
}

test "CancellationToken: cancel and reset" {
    var token = CancellationToken{};
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "ResponseWriter: write and output" {
    var buf: [64]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.write("hello ");
    w.write("world");
    try std.testing.expectEqualSlices(u8, "hello world", w.output());
}

test "ResponseWriter: print formatted" {
    var buf: [64]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.print("count={d}", .{42});
    try std.testing.expectEqualSlices(u8, "count=42", w.output());
}

test "ResponseWriter: overflow truncates" {
    var buf: [5]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.write("hello world");
    try std.testing.expectEqualSlices(u8, "hello", w.output());
}

test "Shell: register and dispatch" {
    const handler = struct {
        pub fn serve(req: *const Request, w: *ResponseWriter) void {
            _ = req;
            w.write("ok");
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("echo", handler, null);

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("echo", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "ok", writer.output());
    try std.testing.expectEqual(@as(i8, 0), writer.exit_code);
}

test "Shell: unknown command sets error" {
    var shell = Shell.init();
    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("nonexistent", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqual(@as(i8, 1), writer.exit_code);
    try std.testing.expectEqualSlices(u8, "unknown command", writer.err_msg);
}

test "Shell: handler receives args and user_ctx" {
    const Counter = struct { value: u32 = 0 };
    var counter = Counter{};

    const handler = struct {
        pub fn serve(req: *const Request, w: *ResponseWriter) void {
            const ctr: *Counter = @ptrCast(@alignCast(req.user_ctx));
            ctr.value += 1;
            w.print("args={s}", .{req.args});
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("test", handler, @ptrCast(&counter));

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("test", "foo bar", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "args=foo bar", writer.output());
    try std.testing.expectEqual(@as(u32, 1), counter.value);
}

test "parseRequest: valid JSON" {
    const parsed = parseRequest("{\"cmd\":\"ls -la\",\"id\":42}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "ls", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "-la", parsed.args);
    try std.testing.expectEqual(@as(u32, 42), parsed.id);
}

test "parseRequest: no args" {
    const parsed = parseRequest("{\"cmd\":\"sys.info\",\"id\":1}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "sys.info", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "", parsed.args);
    try std.testing.expectEqual(@as(u32, 1), parsed.id);
}

test "parseRequest: invalid JSON returns null" {
    try std.testing.expect(parseRequest("garbage") == null);
    try std.testing.expect(parseRequest("{}") == null);
    try std.testing.expect(parseRequest("{\"cmd\":\"ls\"}") == null);
}

test "encodeResponse: basic" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 1, "file1\nfile2", "", 0);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"file1\\nfile2\",\"err\":\"\",\"exit\":0}", resp);
}

test "encodeResponse: with error" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 5, "", "not found", 1);
    try std.testing.expectEqualSlices(u8, "{\"id\":5,\"out\":\"\",\"err\":\"not found\",\"exit\":1}", resp);
}

test "encodeResponse: negative exit code" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 1, "", "killed", -1);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"\",\"err\":\"killed\",\"exit\":-1}", resp);
}
