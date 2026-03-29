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

        pub fn init(rd: *Reader, buf: []u8) Self {
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

        fn stream(r: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
            try fill(r);
            return 0;
        }

        fn fill(r: *Io.Reader) Io.Reader.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));

            if (r.buffer.len == r.end) {
                try r.rebase(r.buffer.len);
            }

            const n = readSome(self.rd, r.buffer[r.end..]) catch |read_err| switch (read_err) {
                error.EndOfStream => return error.EndOfStream,
                else => {
                    self.read_err = read_err;
                    return error.ReadFailed;
                },
            };
            self.read_err = null;
            if (n == 0) return error.EndOfStream;
            r.end += n;
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
