//! io helpers — generic read/write utilities.
//!
//! Pure helper-side utilities that work with any type exposing a compatible
//! `read` method. Runtime subsystem-specific contracts should continue to live
//! with the subsystem itself.

const std = @import("std");
const read_chunk_len = 1024;

pub fn readFull(comptime Reader: type, reader: *Reader, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try reader.read(buf[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

pub fn writeAll(comptime Writer: type, writer: *Writer, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = try writer.write(buf[written..]);
        if (n == 0) return error.Unexpected;
        written += n;
    }
}

pub fn readAll(comptime Reader: type, reader: *Reader, allocator: std.mem.Allocator) ![]u8 {
    var bytes = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer bytes.deinit(allocator);

    const buf = try allocator.alloc(u8, read_chunk_len);
    defer allocator.free(buf);

    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;
        try bytes.appendSlice(allocator, buf[0..n]);
    }

    return bytes.toOwnedSlice(allocator);
}

pub fn PrefixReader(comptime Reader: type) type {
    return struct {
        reader: Reader,
        prefix: []const u8 = &.{},
        prefix_offset: usize = 0,

        const Self = @This();

        pub fn init(reader: Reader, prefix: []const u8) Self {
            return .{
                .reader = reader,
                .prefix = prefix,
            };
        }

        pub fn read(self: *Self, buf: []u8) anyerror!usize {
            if (buf.len == 0) return 0;

            if (self.prefix_offset < self.prefix.len) {
                const remaining = self.prefix[self.prefix_offset..];
                const n = @min(buf.len, remaining.len);
                @memcpy(buf[0..n], remaining[0..n]);
                self.prefix_offset += n;
                return n;
            }

            return self.reader.read(buf);
        }

        pub fn readByte(self: *Self) anyerror!u8 {
            var one: [1]u8 = undefined;
            const n = try self.read(&one);
            if (n == 0) return error.EndOfStream;
            return one[0];
        }

        pub fn readLine(self: *Self, buf: []u8) anyerror![]const u8 {
            var len: usize = 0;
            while (true) {
                if (len == buf.len) return error.BufferTooSmall;
                buf[len] = try self.readByte();
                len += 1;
                if (len >= 2 and buf[len - 2] == '\r' and buf[len - 1] == '\n') {
                    return buf[0 .. len - 2];
                }
            }
        }

        pub fn expectCrlf(self: *Self) anyerror!void {
            if (try self.readByte() != '\r') return error.InvalidResponse;
            if (try self.readByte() != '\n') return error.InvalidResponse;
        }
    };
}

test "readAll reads until eof" {
    const Reader = struct {
        payload: []const u8 = "hello",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = Reader{};
    const bytes = try readAll(Reader, &reader, std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings("hello", bytes);
}

test "readFull fills destination buffer" {
    const Reader = struct {
        payload: []const u8 = "hello",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = Reader{};
    var buf: [5]u8 = undefined;
    try readFull(Reader, &reader, &buf);

    try std.testing.expectEqualStrings("hello", &buf);
}

test "writeAll writes full payload" {
    const Writer = struct {
        out: []u8,
        pos: usize = 0,

        fn write(self: *@This(), buf: []const u8) !usize {
            const n = @min(2, buf.len);
            @memcpy(self.out[self.pos..][0..n], buf[0..n]);
            self.pos += n;
            return n;
        }
    };

    var storage: [5]u8 = undefined;
    var writer = Writer{ .out = &storage };
    try writeAll(Writer, &writer, "hello");
    try std.testing.expectEqualStrings("hello", &storage);
}

test "readFull returns EndOfStream on short read" {
    const Reader = struct {
        payload: []const u8 = "hi",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = Reader{};
    var buf: [5]u8 = undefined;

    try std.testing.expectError(error.EndOfStream, readFull(Reader, &reader, &buf));
}

test "PrefixReader consumes prefix before reader" {
    const Reader = struct {
        payload: []const u8 = "world",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "hello ");
    var buf: [16]u8 = undefined;
    const n = try reader.read(&buf);

    try std.testing.expectEqualStrings("hello ", buf[0..n]);

    const m = try reader.read(buf[n..]);
    try std.testing.expectEqualStrings("hello world", buf[0 .. n + m]);
}

test "PrefixReader readLine and expectCrlf" {
    const Reader = struct {
        payload: []const u8 = "tail\r\n",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "line\r\n");
    var line_buf: [16]u8 = undefined;

    const line = try reader.readLine(&line_buf);
    try std.testing.expectEqualStrings("line", line);

    const tail = try reader.readLine(&line_buf);
    try std.testing.expectEqualStrings("tail", tail);
}
