const zig = @import("std");
const embed = @import("embed");

pub fn make(comptime lib: type, comptime Event: type) type {
    const Http = embed.net.make(lib).http;

    return struct {
        rw: *Http.ResponseWriter,
        started: bool = false,

        const Self = @This();

        pub fn init(rw: *Http.ResponseWriter) Self {
            return .{ .rw = rw };
        }

        pub fn begin(self: *Self, status_code: u16) !void {
            try self.beginWithContentType(status_code, "text/event-stream");
        }

        pub fn beginWithContentType(self: *Self, status_code: u16, content_type: []const u8) !void {
            if (self.started) return;
            try writePreludeTo(self.rw, status_code, content_type);
            self.started = true;
        }

        pub fn writePrelude(self: *Self) !void {
            try self.begin(Http.status.ok);
        }

        pub fn event(self: *Self, evt: Event) !void {
            if (!self.started) try self.writePrelude();
            try writeEventTo(self.rw, evt);
        }

        pub fn flush(self: *Self) !void {
            try self.rw.flush();
        }
    };
}

fn writePreludeTo(rw: anytype, status_code: u16, content_type: []const u8) !void {
    if (@hasDecl(@TypeOf(rw.*), "setKeepAlive")) rw.setKeepAlive(true);
    try rw.setHeader("Content-Type", content_type);
    try rw.setHeader("Cache-Control", "no-cache");
    try rw.writeHeader(status_code);
}

fn writeEventTo(rw: anytype, evt: anytype) !void {
    if (evt.event) |value| try writeFieldLine(rw, "event", value);
    if (evt.id) |value| try writeFieldLine(rw, "id", value);
    if (evt.retry) |value| {
        var retry_buf: [32]u8 = undefined;
        const text = try zig.fmt.bufPrint(&retry_buf, "{d}", .{value});
        try writeFieldLine(rw, "retry", text);
    }
    if (evt.data) |value| {
        try writeDataLines(rw, value);
    }
    try writeAll(rw, "\n");
}

fn writeFieldLine(rw: anytype, name: []const u8, value: []const u8) !void {
    try writeAll(rw, name);
    if (value.len == 0) {
        try writeAll(rw, ":\n");
        return;
    }
    try writeAll(rw, ": ");
    try writeAll(rw, value);
    try writeAll(rw, "\n");
}

fn writeDataLines(rw: anytype, value: []const u8) !void {
    if (value.len == 0) {
        try writeFieldLine(rw, "data", "");
        return;
    }

    var start: usize = 0;
    while (true) {
        const newline = zig.mem.indexOfScalarPos(u8, value, start, '\n') orelse {
            try writeFieldLine(rw, "data", trimTrailingCarriageReturn(value[start..]));
            return;
        };
        try writeFieldLine(rw, "data", trimTrailingCarriageReturn(value[start..newline]));
        start = newline + 1;
        if (start > value.len) return;
    }
}

fn writeAll(rw: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try rw.write(bytes[offset..]);
    }
}

fn trimTrailingCarriageReturn(value: []const u8) []const u8 {
    if (value.len != 0 and value[value.len - 1] == '\r') return value[0 .. value.len - 1];
    return value;
}

pub fn TestRunner(comptime lib: type, comptime testing_api: anytype) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const EventLocal = struct {
                event: ?[]const u8 = null,
                id: ?[]const u8 = null,
                data: ?[]const u8 = null,
                retry: ?u64 = null,
            };
            const Header = struct {
                name: []const u8,
                value: []const u8,
            };

            const MockResponseWriter = struct {
                allocator: lib.mem.Allocator,
                headers: lib.ArrayList(Header) = .{},
                body: lib.ArrayList(u8) = .{},
                status_code: u16 = 0,
                committed: bool = false,
                keep_alive: bool = false,
                flush_calls: usize = 0,

                pub fn init(a: lib.mem.Allocator) @This() {
                    return .{ .allocator = a };
                }

                pub fn deinit(self: *@This()) void {
                    self.headers.deinit(self.allocator);
                    self.body.deinit(self.allocator);
                }

                pub fn setKeepAlive(self: *@This(), keep_alive: bool) void {
                    self.keep_alive = keep_alive;
                }

                pub fn setHeader(self: *@This(), name: []const u8, value: []const u8) !void {
                    for (self.headers.items) |*header| {
                        if (zig.mem.eql(u8, header.name, name)) {
                            header.value = value;
                            return;
                        }
                    }
                    try self.headers.append(self.allocator, .{ .name = name, .value = value });
                }

                pub fn writeHeader(self: *@This(), status_code: u16) !void {
                    self.status_code = status_code;
                    self.committed = true;
                }

                pub fn write(self: *@This(), bytes: []const u8) !usize {
                    try self.body.appendSlice(self.allocator, bytes);
                    return bytes.len;
                }

                pub fn flush(self: *@This()) !void {
                    self.flush_calls += 1;
                }

                fn headerValue(self: *@This(), name: []const u8) ?[]const u8 {
                    for (self.headers.items) |header| {
                        if (zig.mem.eql(u8, header.name, name)) return header.value;
                    }
                    return null;
                }
            };
            {
                var rw = MockResponseWriter.init(allocator);
                defer rw.deinit();

                try writePreludeTo(&rw, 200, "text/event-stream");
                try zig.testing.expectEqual(@as(u16, 200), rw.status_code);
                try zig.testing.expectEqualStrings("text/event-stream", rw.headerValue("Content-Type").?);
                try zig.testing.expectEqualStrings("no-cache", rw.headerValue("Cache-Control").?);
                try zig.testing.expect(rw.keep_alive);
            }

            {
                var rw = MockResponseWriter.init(allocator);
                defer rw.deinit();

                try writePreludeTo(&rw, 200, "text/event-stream; charset=utf-8");
                try zig.testing.expectEqualStrings("text/event-stream; charset=utf-8", rw.headerValue("Content-Type").?);
            }

            {
                var rw = MockResponseWriter.init(allocator);
                defer rw.deinit();

                try writeEventTo(&rw, EventLocal{
                    .event = "message",
                    .id = "7",
                    .data = "hello\nworld",
                    .retry = 1500,
                });
                try zig.testing.expectEqualStrings(
                    "event: message\nid: 7\nretry: 1500\ndata: hello\ndata: world\n\n",
                    rw.body.items,
                );
            }

            {
                var rw = MockResponseWriter.init(allocator);
                defer rw.deinit();

                try writeEventTo(&rw, EventLocal{ .data = "" });
                try zig.testing.expectEqualStrings("data:\n\n", rw.body.items);
            }

        }
    }.run);
}
