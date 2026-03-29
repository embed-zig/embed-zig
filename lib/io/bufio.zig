//! bufio — buffered I/O adapters over `std.Io`.
//!
//! `BufferedReader(Reader)` follows the `std.fs.File.reader()` style:
//! construct a concrete adapter value first, then borrow its `Io.Reader`
//! interface via `ioReader()`.

const std = @import("std");
const Io = @import("embed").Io;

pub fn BufferedReader(comptime Reader: type) type {
    return struct {
        buffer_allocator: ?std.mem.Allocator = null,
        rd: *Reader,
        read_err: ?anyerror = null,
        interface: Io.Reader,

        const Self = @This();

        fn initInterface(buffer: []u8) Io.Reader {
            return .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            };
        }

        /// `buf` must be non-empty.
        pub fn init(rd: *Reader, buf: []u8) Self {
            std.debug.assert(buf.len > 0);
            return .{
                .rd = rd,
                .interface = initInterface(buf),
            };
        }

        pub fn initAlloc(rd: *Reader, allocator: std.mem.Allocator, bufsize: usize) std.mem.Allocator.Error!Self {
            const buffer = try allocator.alloc(u8, @max(@as(usize, 1), bufsize));
            return .{
                .buffer_allocator = allocator,
                .rd = rd,
                .interface = initInterface(buffer),
            };
        }

        pub fn ioReader(self: *Self) *Io.Reader {
            return &self.interface;
        }

        /// Returns the underlying non-EOF read error after the `Io.Reader`
        /// surface reports `error.ReadFailed`.
        pub fn err(self: *const Self) ?anyerror {
            return self.read_err;
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer_allocator) |allocator| {
                allocator.free(self.interface.buffer);
                self.buffer_allocator = null;
            }
        }

        fn readVec(r: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
            try fill(r);
            return 0;
        }

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));

            if (!limit.nonzero()) return 0;

            var scratch: [256]u8 = undefined;
            const dest = limit.slice(&scratch);
            const n = readInto(self, dest) catch |read_err| switch (read_err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            try w.writeAll(dest[0..n]);
            return n;
        }

        fn fill(r: *Io.Reader) Io.Reader.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));

            try ensureTailCapacity(self, r);

            const dest = r.buffer[r.end..];
            std.debug.assert(dest.len > 0);

            const n = readInto(self, dest) catch |read_err| switch (read_err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            r.end += n;
        }

        fn ensureTailCapacity(self: *Self, r: *Io.Reader) Io.Reader.Error!void {
            if (r.end < r.buffer.len) return;

            if (r.seek == 0) {
                self.read_err = error.BufferTooSmall;
                return error.ReadFailed;
            }

            try r.rebase(r.end - r.seek + 1);
            if (r.end == r.buffer.len) {
                self.read_err = error.BufferTooSmall;
                return error.ReadFailed;
            }
        }

        fn readInto(self: *Self, dest: []u8) anyerror!usize {
            const n = readSome(self.rd, dest) catch |read_err| switch (read_err) {
                error.EndOfStream => {
                    self.read_err = null;
                    return error.EndOfStream;
                },
                else => {
                    self.read_err = read_err;
                    return read_err;
                },
            };
            self.read_err = null;
            return n;
        }

        fn readSome(reader: *Reader, buf: []u8) anyerror!usize {
            if (Reader == Io.Reader or Reader == std.Io.Reader) {
                return reader.readSliceShort(buf);
            }
            if (@hasDecl(Reader, "read")) {
                return reader.read(buf);
            }
            if (@hasDecl(Reader, "readSliceShort")) {
                return reader.readSliceShort(buf);
            }
            @compileError("io.BufferedReader requires a reader with read([]u8)!usize or std.Io.Reader-compatible readSliceShort([]u8).");
        }
    };
}

test "io/unit_tests/bufio/BufferedReader_initAlloc_supports_peek_and_take" {
    var src = Io.Reader.fixed("hello\r\nworld");
    var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, std.testing.allocator, 16);
    defer br.deinit();
    const reader = br.ioReader();

    const peeked = try reader.peek(5);
    try std.testing.expectEqualStrings("hello", peeked);
    try std.testing.expectEqualStrings("h", try reader.take(1));

    const rest = try reader.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("ello\r\n", rest);
}

test "io/unit_tests/bufio/BufferedReader_init_supports_text_protocol_style_reads" {
    var src = Io.Reader.fixed("PING a\r\nPONG b\r\n");
    var backing: [32]u8 = undefined;
    var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
    const reader = br.ioReader();

    const line1 = try reader.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("PING a\r\n", line1);

    const line2 = try reader.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("PONG b\r\n", line2);
}

test "io/unit_tests/bufio/BufferedReader_small_buffer_supports_rebase_across_lines" {
    var src = Io.Reader.fixed("ab\r\ncd\r\n");
    var backing: [6]u8 = undefined;
    var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
    const reader = br.ioReader();

    const line1 = try reader.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("ab\r\n", line1);

    const line2 = try reader.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("cd\r\n", line2);
}

test "io/unit_tests/bufio/BufferedReader_reports_StreamTooLong_for_overlong_line" {
    var src = Io.Reader.fixed("abcdX\n");
    var backing: [4]u8 = undefined;
    var br = BufferedReader(@TypeOf(src)).init(&src, &backing);

    try std.testing.expectError(error.StreamTooLong, br.ioReader().takeDelimiterInclusive('\n'));
}

test "io/unit_tests/bufio/BufferedReader_initAlloc_zero_bufsize_still_reads" {
    var src = Io.Reader.fixed("ok");
    var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, std.testing.allocator, 0);
    defer br.deinit();

    try std.testing.expect(br.ioReader().buffer.len >= 1);
    try std.testing.expectEqualStrings("o", try br.ioReader().take(1));
}

test "io/unit_tests/bufio/BufferedReader_err_preserves_and_clears_underlying_failure" {
    const Reader = struct {
        payload: []const u8 = "ok",
        offset: usize = 0,
        fail_once: bool = true,

        fn read(self: *@This(), buf: []u8) anyerror!usize {
            if (self.fail_once) {
                self.fail_once = false;
                return error.ConnectionReset;
            }

            const remaining = self.payload[self.offset..];
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            self.offset += n;
            return n;
        }
    };

    var src = Reader{};
    var backing: [4]u8 = undefined;
    var br = BufferedReader(Reader).init(&src, &backing);
    const reader = br.ioReader();

    try std.testing.expectError(error.ReadFailed, reader.peek(1));
    try std.testing.expect(br.err() != null);
    try std.testing.expect(br.err().? == error.ConnectionReset);

    try std.testing.expectEqualStrings("o", try reader.take(1));
    try std.testing.expect(br.err() == null);
}

test "io/unit_tests/bufio/BufferedReader_reports_BufferTooSmall_via_err_when_window_cannot_grow" {
    var src = Io.Reader.fixed("ab");
    var backing: [1]u8 = undefined;
    var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
    const reader = br.ioReader();

    try std.testing.expectEqualStrings("a", try reader.peek(1));

    var empty: [0]u8 = .{};
    var bufs = [_][]u8{&empty};
    try std.testing.expectError(error.ReadFailed, @TypeOf(br).readVec(reader, &bufs));
    try std.testing.expect(br.err() != null);
    try std.testing.expect(br.err().? == error.BufferTooSmall);
}
