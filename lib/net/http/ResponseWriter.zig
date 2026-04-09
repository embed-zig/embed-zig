//! ResponseWriter — server-side HTTP response construction surface.

const io = @import("io");
const Conn = @import("../Conn.zig");
const Header = @import("Header.zig");
const Request = @import("Request.zig");
const status = @import("status.zig");
const testing_api = @import("testing");

pub fn ResponseWriter(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;

    return struct {
        allocator: Allocator,
        conn: Conn,
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

            if (self.use_chunked) {
                var prefix_buf: [32]u8 = undefined;
                const prefix = try lib.fmt.bufPrint(&prefix_buf, "{x}\r\n", .{buf.len});
                try io.writeAll(@TypeOf(self.conn), &self.conn, prefix);
                try io.writeAll(@TypeOf(self.conn), &self.conn, buf);
                try io.writeAll(@TypeOf(self.conn), &self.conn, "\r\n");
            } else {
                try io.writeAll(@TypeOf(self.conn), &self.conn, buf);
            }

            return buf.len;
        }

        pub fn finish(self: *Self) !void {
            if (self.finished_flag) return;
            if (!self.committed_flag) try self.writeHeader(self.status_code);
            if (self.use_chunked and self.body_allowed) {
                try io.writeAll(@TypeOf(self.conn), &self.conn, "0\r\n\r\n");
            }
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

            var head = lib.ArrayList(u8){};
            defer head.deinit(self.allocator);

            try head.appendSlice(self.allocator, "HTTP/1.1 ");
            const reason = status.text(self.status_code) orelse "Unknown";
            var code_buf: [32]u8 = undefined;
            const code = try lib.fmt.bufPrint(&code_buf, "{d}", .{self.status_code});
            try head.appendSlice(self.allocator, code);
            try head.appendSlice(self.allocator, " ");
            try head.appendSlice(self.allocator, reason);
            try head.appendSlice(self.allocator, "\r\n");
            for (self.header.items) |hdr| {
                if (!self.body_allowed and hdr.is(Header.transfer_encoding)) continue;
                try head.appendSlice(self.allocator, hdr.name);
                try head.appendSlice(self.allocator, ": ");
                try head.appendSlice(self.allocator, hdr.value);
                try head.appendSlice(self.allocator, "\r\n");
            }
            try head.appendSlice(self.allocator, "\r\n");

            try io.writeAll(@TypeOf(self.conn), &self.conn, head.items);
            self.committed_flag = true;
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
    return testing_api.TestRunner.fromFn(lib, 0, struct {
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
        }
    }.run);
}
