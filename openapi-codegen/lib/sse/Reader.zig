const zig = @import("std");
const embed = @import("embed");

pub fn make(comptime lib: type, comptime Event: type) type {
    const std = lib;
    const Http = embed.net.make(lib).http;

    return struct {
        allocator: std.mem.Allocator,
        body: Http.ReadCloser,
        buffer: std.ArrayList(u8) = .{},
        cursor: usize = 0,
        eof: bool = false,
        current_event: Event = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, body: Http.ReadCloser) Self {
            return .{
                .allocator = allocator,
                .body = body,
            };
        }

        /// Closes the underlying HTTP body. Call this before outer response teardown.
        pub fn deinit(self: *Self) void {
            self.current_event.deinit(self.allocator);
            self.buffer.deinit(self.allocator);
            self.body.close();
            self.* = undefined;
        }

        /// Returned event field slices stay valid until the next `next()` call or
        /// `deinit()`.
        pub fn next(self: *Self) !?Event {
            self.current_event.deinit(self.allocator);

            var event: Event = .{};
            errdefer event.deinit(self.allocator);

            var data_builder: std.ArrayList(u8) = .{};
            defer data_builder.deinit(self.allocator);

            var has_fields = false;
            var saw_data_field = false;

            while (true) {
                const maybe_line = try self.nextLine();
                const line = maybe_line orelse {
                    if (has_fields) return error.UnexpectedEof;
                    return null;
                };

                if (line.len == 0) {
                    if (!has_fields) continue;
                    if (saw_data_field) event.data = try self.allocator.dupe(u8, data_builder.items);
                    self.current_event = event;
                    event = .{};
                    return self.current_event;
                }

                if (line[0] == ':') continue;

                const colon = zig.mem.indexOfScalar(u8, line, ':');
                const name = if (colon) |idx| line[0..idx] else line;
                const raw_value = if (colon) |idx| blk: {
                    var start = idx + 1;
                    if (start < line.len and line[start] == ' ') start += 1;
                    break :blk line[start..];
                } else "";

                if (zig.mem.eql(u8, name, "data")) {
                    has_fields = true;
                    saw_data_field = true;
                    if (data_builder.items.len != 0) try data_builder.append(self.allocator, '\n');
                    try data_builder.appendSlice(self.allocator, raw_value);
                    continue;
                }
                if (zig.mem.eql(u8, name, "event")) {
                    has_fields = true;
                    try replaceOwned(self.allocator, &event.event, raw_value);
                    continue;
                }
                if (zig.mem.eql(u8, name, "id")) {
                    if (zig.mem.indexOfScalar(u8, raw_value, 0) != null) continue;
                    has_fields = true;
                    try replaceOwned(self.allocator, &event.id, raw_value);
                    continue;
                }
                if (zig.mem.eql(u8, name, "retry")) {
                    has_fields = true;
                    event.retry = try zig.fmt.parseInt(u64, raw_value, 10);
                    continue;
                }
            }
        }

        fn nextLine(self: *Self) !?[]u8 {
            while (true) {
                if (zig.mem.indexOfScalarPos(u8, self.buffer.items, self.cursor, '\n')) |newline| {
                    const line = trimTrailingCarriageReturn(self.buffer.items[self.cursor..newline]);
                    self.cursor = newline + 1;
                    if (self.cursor == self.buffer.items.len) {
                        self.buffer.items.len = 0;
                        self.cursor = 0;
                    }
                    return line;
                }

                if (self.eof) {
                    if (self.cursor >= self.buffer.items.len) {
                        self.buffer.items.len = 0;
                        self.cursor = 0;
                        return null;
                    }
                    const line = trimTrailingCarriageReturn(self.buffer.items[self.cursor..]);
                    self.buffer.items.len = 0;
                    self.cursor = 0;
                    return line;
                }

                try self.fillBuffer();
            }
        }

        fn fillBuffer(self: *Self) !void {
            if (self.cursor != 0 and self.cursor == self.buffer.items.len) {
                self.buffer.items.len = 0;
                self.cursor = 0;
            } else if (self.cursor != 0) {
                const remaining = self.buffer.items[self.cursor..];
                std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
                self.buffer.items.len = remaining.len;
                self.cursor = 0;
            }

            var chunk: [256]u8 = undefined;
            const amount = try self.body.read(&chunk);
            if (amount == 0) {
                self.eof = true;
                return;
            }
            try self.buffer.appendSlice(self.allocator, chunk[0..amount]);
        }
    };
}

fn replaceOwned(allocator: anytype, slot: *?[]const u8, value: []const u8) !void {
    if (slot.*) |owned| allocator.free(owned);
    slot.* = try allocator.dupe(u8, value);
}

fn trimTrailingCarriageReturn(line: []u8) []u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

pub fn TestRunner(comptime lib: type, comptime testing_api: anytype) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(lib, 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const Http = embed.net.make(lib).http;
            const Event = struct {
                event: ?[]const u8 = null,
                id: ?[]const u8 = null,
                data: ?[]const u8 = null,
                retry: ?u64 = null,

                pub fn deinit(self: *@This(), a: lib.mem.Allocator) void {
                    if (self.event) |value| a.free(value);
                    if (self.id) |value| a.free(value);
                    if (self.data) |value| a.free(value);
                    self.* = .{};
                }
            };
            const Reader = make(lib, Event);

            const ChunkedBody = struct {
                parts: []const []const u8,
                part: usize = 0,
                closed: bool = false,

                pub fn read(self: *@This(), buf: []u8) !usize {
                    if (self.part >= self.parts.len) return 0;
                    const cur = self.parts[self.part];
                    const amount = @min(buf.len, cur.len);
                    @memcpy(buf[0..amount], cur[0..amount]);
                    self.part += 1;
                    return amount;
                }

                pub fn close(self: *@This()) void {
                    self.closed = true;
                }
            };

            {
                var body = ChunkedBody{
                    .parts = &.{
                        "event: message\r\nid: 1\r\n",
                        "data: hello\r\n\r\n",
                        "data: world\n\n",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();

                const first = (try reader.next()) orelse return error.ExpectedEvent;
                try zig.testing.expectEqualStrings("message", first.event.?);
                try zig.testing.expectEqualStrings("1", first.id.?);
                try zig.testing.expectEqualStrings("hello", first.data.?);

                const second = (try reader.next()) orelse return error.ExpectedSecondEvent;
                try zig.testing.expectEqualStrings("world", second.data.?);
                try zig.testing.expect(second.event == null);
                try zig.testing.expect(second.id == null);
                try zig.testing.expect((try reader.next()) == null);
            }

            {
                var body = ChunkedBody{
                    .parts = &.{
                        "data: first\n",
                        "data: second\n\n",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();

                const value = (try reader.next()) orelse return error.ExpectedMultilineEvent;
                try zig.testing.expectEqualStrings("first\nsecond", value.data.?);
            }

            {
                var body = ChunkedBody{
                    .parts = &.{
                        ": heartbeat\n",
                        "retry: 1500\n\n",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();

                const value = (try reader.next()) orelse return error.ExpectedRetryEvent;
                try zig.testing.expectEqual(@as(?u64, 1500), value.retry);
            }

            {
                var body = ChunkedBody{
                    .parts = &.{
                        "data: missing-terminator",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();
                try zig.testing.expectError(error.UnexpectedEof, reader.next());
            }

            {
                var body = ChunkedBody{
                    .parts = &.{
                        "retry: nope\n\n",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();
                try zig.testing.expectError(error.InvalidCharacter, reader.next());
            }

            {
                var body = ChunkedBody{
                    .parts = &.{
                        "id: bad",
                        "\x00",
                        "id\n",
                        "data: ok\n\n",
                    },
                };
                var reader = Reader.init(allocator, Http.ReadCloser.init(&body));
                defer reader.deinit();

                const value = (try reader.next()) orelse return error.ExpectedNullIdEvent;
                try zig.testing.expect(value.id == null);
                try zig.testing.expectEqualStrings("ok", value.data.?);
            }
        }
    }.run);
}
