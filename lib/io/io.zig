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

/// Writes until the full payload is consumed.
///
/// A zero-length write is treated as `error.Unexpected` because the writer made
/// no progress.
pub fn writeAll(comptime Writer: type, writer: *Writer, buf: []const u8) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = try writer.write(buf[written..]);
        if (n == 0) return error.Unexpected;
        written += n;
    }
}

/// Reads until EOF, where EOF may be signaled by either a zero-length read or
/// `error.EndOfStream`.
pub fn readAll(comptime Reader: type, reader: *Reader, allocator: std.mem.Allocator) ![]u8 {
    var bytes = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer bytes.deinit(allocator);

    const buf = try allocator.alloc(u8, read_chunk_len);
    defer allocator.free(buf);

    while (true) {
        const n = reader.read(buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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

        /// Reads a single CRLF-terminated line and returns the bytes before the
        /// trailing `\r\n`.
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

test "io/unit_tests/io/readAll_reads_until_eof" {
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

test "io/unit_tests/io/readAll_accepts_EndOfStream_as_eof" {
    const Reader = struct {
        payload: []const u8 = "hello",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            if (self.offset >= self.payload.len) return error.EndOfStream;

            const remaining = self.payload[self.offset..];
            const n = @min(2, @min(buf.len, remaining.len));
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

test "io/unit_tests/io/readAll_returns_empty_slice_when_reader_immediately_ends" {
    const Reader = struct {
        fn read(_: *@This(), _: []u8) anyerror!usize {
            return error.EndOfStream;
        }
    };

    var reader = Reader{};
    const bytes = try readAll(Reader, &reader, std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "io/unit_tests/io/readAll_returns_empty_slice_on_zero_length_read" {
    const Reader = struct {
        fn read(_: *@This(), _: []u8) anyerror!usize {
            return 0;
        }
    };

    var reader = Reader{};
    const bytes = try readAll(Reader, &reader, std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "io/unit_tests/io/readAll_propagates_non_eof_error" {
    const Reader = struct {
        called: bool = false,

        fn read(self: *@This(), _: []u8) anyerror!usize {
            if (!self.called) {
                self.called = true;
                return error.ConnectionReset;
            }
            unreachable;
        }
    };

    var reader = Reader{};
    try std.testing.expectError(error.ConnectionReset, readAll(Reader, &reader, std.testing.allocator));
}

test "io/unit_tests/io/readFull_fills_destination_buffer" {
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

test "io/unit_tests/io/writeAll_writes_full_payload" {
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

test "io/unit_tests/io/readFull_returns_EndOfStream_on_short_read" {
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

test "io/unit_tests/io/readFull_propagates_EndOfStream_error" {
    const Reader = struct {
        payload: []const u8 = "hi",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            if (self.offset >= self.payload.len) return error.EndOfStream;

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

test "io/unit_tests/io/readFull_with_empty_buffer_is_noop" {
    const Reader = struct {
        called: bool = false,

        fn read(self: *@This(), _: []u8) anyerror!usize {
            self.called = true;
            return 0;
        }
    };

    var reader = Reader{};
    var buf: [0]u8 = .{};
    try readFull(Reader, &reader, &buf);
    try std.testing.expect(!reader.called);
}

test "io/unit_tests/io/PrefixReader_consumes_prefix_before_reader" {
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

test "io/unit_tests/io/PrefixReader_readByte_crosses_prefix_and_reader_boundary" {
    const Reader = struct {
        payload: []const u8 = "cd",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "ab");
    try std.testing.expectEqual('a', try reader.readByte());
    try std.testing.expectEqual('b', try reader.readByte());
    try std.testing.expectEqual('c', try reader.readByte());
    try std.testing.expectEqual('d', try reader.readByte());
    try std.testing.expectError(error.EndOfStream, reader.readByte());
}

test "io/unit_tests/io/PrefixReader_readLine_reads_crlf_terminated_lines" {
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

test "io/unit_tests/io/PrefixReader_readLine_returns_EndOfStream_without_trailing_crlf" {
    const Reader = struct {
        payload: []const u8 = "tail",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "");
    var line_buf: [16]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, reader.readLine(&line_buf));
}

test "io/unit_tests/io/PrefixReader_readLine_returns_BufferTooSmall_for_long_line" {
    const Reader = struct {
        payload: []const u8 = "abcd\r\n",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "");
    var line_buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, reader.readLine(&line_buf));
}

test "io/unit_tests/io/PrefixReader_expectCrlf_accepts_and_rejects_line_endings" {
    const Reader = struct {
        payload: []const u8 = "\r\nx\n",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "");
    try reader.expectCrlf();
    try std.testing.expectError(error.InvalidResponse, reader.expectCrlf());
}

test "io/unit_tests/io/PrefixReader_expectCrlf_crosses_prefix_and_reader_boundary" {
    const Reader = struct {
        payload: []const u8 = "\n",
        offset: usize = 0,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var reader = PrefixReader(Reader).init(Reader{}, "\r");
    try reader.expectCrlf();
}

test "io/unit_tests/io/writeAll_returns_Unexpected_on_zero_write" {
    const Writer = struct {
        fn write(_: *@This(), _: []const u8) !usize {
            return 0;
        }
    };

    var writer = Writer{};
    try std.testing.expectError(error.Unexpected, writeAll(Writer, &writer, "hello"));
}

test "io/unit_tests/io/writeAll_propagates_write_error" {
    const Writer = struct {
        calls: usize = 0,

        fn write(self: *@This(), buf: []const u8) !usize {
            if (self.calls == 0) {
                self.calls += 1;
                return @min(@as(usize, 2), buf.len);
            }
            return error.BrokenPipe;
        }
    };

    var writer = Writer{};
    try std.testing.expectError(error.BrokenPipe, writeAll(Writer, &writer, "hello"));
}

test "io/unit_tests/io/writeAll_with_empty_payload_is_noop" {
    const Writer = struct {
        called: bool = false,

        fn write(self: *@This(), _: []const u8) !usize {
            self.called = true;
            return 0;
        }
    };

    var writer = Writer{};
    try writeAll(Writer, &writer, "");
    try std.testing.expect(!writer.called);
}
