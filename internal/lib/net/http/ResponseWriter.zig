//! ResponseWriter — server-side HTTP response construction surface.

const io = @import("io");
const Conn = @import("../Conn.zig");
const Header = @import("Header.zig");
const Request = @import("Request.zig");
const status = @import("status.zig");
const textproto_writer_mod = @import("../textproto/Writer.zig");
const testing_api = @import("testing");

pub fn ResponseWriter(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const BufferedConnWriter = io.BufferedWriter(Conn);
    const TextprotoWriter = textproto_writer_mod.Writer(BufferedConnWriter);
    const write_buf_len = 1024;

    return struct {
        allocator: Allocator,
        conn: Conn,
        buffered: BufferedConnWriter = undefined,
        buffered_initialized: bool = false,
        write_buf: [write_buf_len]u8 = undefined,
        request_method: []const u8 = "GET",
        header: lib.ArrayList(Header) = .{},
        status_code: u16 = status.ok,
        committed_flag: bool = false,
        finished_flag: bool = false,
        body_allowed: bool = true,
        use_chunked: bool = false,
        keep_alive: bool = false,

        const Self = @This();

        pub fn init(allocator: Allocator, conn: Conn, req: ?*const Request, keep_alive: bool) Self {
            return .{
                .allocator = allocator,
                .conn = conn,
                .request_method = if (req) |r| r.effectiveMethod() else "GET",
                .keep_alive = keep_alive,
            };
        }

        pub fn deinit(self: *Self) void {
            self.header.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn committed(self: *const Self) bool {
            return self.committed_flag;
        }

        pub fn setKeepAlive(self: *Self, keep_alive: bool) void {
            if (self.committed_flag) return;
            self.keep_alive = keep_alive;
        }

        pub fn setHeader(self: *Self, name: []const u8, value: []const u8) Allocator.Error!void {
            if (self.committed_flag) return;
            self.removeHeader(name);
            try self.header.append(self.allocator, Header.init(name, value));
        }

        pub fn addHeader(self: *Self, name: []const u8, value: []const u8) Allocator.Error!void {
            if (self.committed_flag) return;
            try self.header.append(self.allocator, Header.init(name, value));
        }

        pub fn writeHeader(self: *Self, status_code: u16) !void {
            if (self.committed_flag) return;
            self.status_code = status_code;
            try self.commitHead();
        }

        pub fn write(self: *Self, buf: []const u8) !usize {
            if (self.finished_flag) return error.Closed;
            if (!self.committed_flag) try self.writeHeader(self.status_code);
            if (!self.body_allowed or buf.len == 0) return buf.len;

            const buffered = self.bufferedWriter();
            if (self.use_chunked) {
                var prefix_buf: [32]u8 = undefined;
                const prefix = try lib.fmt.bufPrint(&prefix_buf, "{x}\r\n", .{buf.len});
                try self.writeAllBuffered(buffered, prefix);
                try self.writeAllBuffered(buffered, buf);
                try self.writeAllBuffered(buffered, "\r\n");
            } else {
                try self.writeAllBuffered(buffered, buf);
            }

            return buf.len;
        }

        pub fn flush(self: *Self) !void {
            if (self.finished_flag) return error.Closed;
            if (!self.committed_flag) try self.writeHeader(self.status_code);
            try self.flushBuffered(self.bufferedWriter());
        }

        pub fn finish(self: *Self) !void {
            if (self.finished_flag) return;
            if (!self.committed_flag) try self.writeHeader(self.status_code);
            const buffered = self.bufferedWriter();
            if (self.use_chunked and self.body_allowed) {
                try self.writeAllBuffered(buffered, "0\r\n\r\n");
            }
            try self.flushBuffered(buffered);
            self.finished_flag = true;
        }

        pub fn wantsKeepAlive(self: *const Self) bool {
            return self.keep_alive;
        }

        fn commitHead(self: *Self) !void {
            self.body_allowed = bodyAllowed(self.request_method, self.status_code);
            const explicit_connection = self.headerValue(Header.connection);
            if (explicit_connection) |value| {
                if (lib.ascii.eqlIgnoreCase(value, "close")) {
                    self.keep_alive = false;
                } else if (lib.ascii.eqlIgnoreCase(value, "keep-alive")) {
                    self.keep_alive = true;
                }
            } else {
                try self.header.append(self.allocator, Header.init(
                    Header.connection,
                    if (self.keep_alive) "keep-alive" else "close",
                ));
            }

            if (!self.body_allowed) {
                self.use_chunked = false;
                if (self.headerValue(Header.content_length) == null) {
                    try self.header.append(self.allocator, Header.init(Header.content_length, "0"));
                }
            } else if (self.headerValue(Header.content_length) != null) {
                self.use_chunked = false;
            } else {
                self.removeHeader(Header.transfer_encoding);
                self.use_chunked = true;
                try self.header.append(self.allocator, Header.init(Header.transfer_encoding, "chunked"));
            }

            const reason = status.text(self.status_code) orelse "Unknown";
            var code_buf: [32]u8 = undefined;
            const code = try lib.fmt.bufPrint(&code_buf, "{d}", .{self.status_code});
            var writer = TextprotoWriter.fromBuffered(self.bufferedWriter());

            try writer.writeLineParts(&.{ "HTTP/1.1 ", code, " ", reason });
            for (self.header.items) |hdr| {
                if (!self.body_allowed and hdr.is(Header.transfer_encoding)) continue;
                try writer.writeLineParts(&.{ hdr.name, ": ", hdr.value });
            }
            try writer.writeLine("");

            self.committed_flag = true;
        }

        fn bufferedWriter(self: *Self) *BufferedConnWriter {
            if (!self.buffered_initialized) {
                self.buffered = BufferedConnWriter.init(&self.conn, &self.write_buf);
                self.buffered_initialized = true;
            }
            return &self.buffered;
        }

        fn writeAllBuffered(self: *Self, buffered: *BufferedConnWriter, buf: []const u8) !void {
            _ = self;
            buffered.ioWriter().writeAll(buf) catch return buffered.err() orelse error.Unexpected;
        }

        fn flushBuffered(self: *Self, buffered: *BufferedConnWriter) !void {
            _ = self;
            buffered.flush() catch return buffered.err() orelse error.Unexpected;
        }

        fn removeHeader(self: *Self, name: []const u8) void {
            var out: usize = 0;
            for (self.header.items) |hdr| {
                if (hdr.is(name)) continue;
                self.header.items[out] = hdr;
                out += 1;
            }
            self.header.items.len = out;
        }

        fn headerValue(self: *const Self, name: []const u8) ?[]const u8 {
            for (self.header.items) |hdr| {
                if (hdr.is(name)) return hdr.value;
            }
            return null;
        }
    };
}

fn bodyAllowed(method: []const u8, status_code: u16) bool {
    if (status_code >= 100 and status_code < 200) return false;
    if (status_code == status.no_content or status_code == status.not_modified) return false;
    if (method.len == 4 and method[0] == 'H' and method[1] == 'E' and method[2] == 'A' and method[3] == 'D') return false;
    return true;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Writer = ResponseWriter(lib);

            var writer = Writer.init(allocator, undefined, null, false);
            defer writer.deinit();

            try writer.setHeader("X-Test", "one");
            writer.committed_flag = true;
            try writer.setHeader("X-Test", "two");

            try testing.expectEqual(@as(usize, 1), writer.header.items.len);
            try testing.expectEqualStrings("one", writer.header.items[0].value);

            try testing.expect(!bodyAllowed("HEAD", status.ok));
            try testing.expect(!bodyAllowed("GET", status.no_content));
            try testing.expect(bodyAllowed("GET", status.ok));

            const MockConn = struct {
                storage: [256]u8 = undefined,
                len: usize = 0,

                pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                    return 0;
                }

                pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                    if (buf.len > self.storage.len - self.len) return error.Unexpected;
                    @memcpy(self.storage[self.len..][0..buf.len], buf);
                    self.len += buf.len;
                    return buf.len;
                }

                pub fn close(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
            };

            var mock_conn = MockConn{};
            var response_writer = Writer.init(allocator, Conn.init(&mock_conn), null, false);
            defer response_writer.deinit();

            try response_writer.setHeader("Content-Type", "text/plain");
            _ = try response_writer.write("ok");
            try testing.expectEqual(@as(usize, 0), mock_conn.len);

            try response_writer.flush();

            try testing.expectEqualStrings(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/plain\r\n" ++
                    "Connection: close\r\n" ++
                    "Transfer-Encoding: chunked\r\n" ++
                    "\r\n" ++
                    "2\r\n" ++
                    "ok\r\n",
                mock_conn.storage[0..mock_conn.len],
            );

            try response_writer.finish();

            try testing.expectEqualStrings(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/plain\r\n" ++
                    "Connection: close\r\n" ++
                    "Transfer-Encoding: chunked\r\n" ++
                    "\r\n" ++
                    "2\r\n" ++
                    "ok\r\n" ++
                    "0\r\n\r\n",
                mock_conn.storage[0..mock_conn.len],
            );
        }
    }.run);
}
