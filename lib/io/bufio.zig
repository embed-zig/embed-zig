//! bufio — buffered I/O adapters over `embed.Io`.
//!
//! `BufferedReader(Reader)` follows the usual concrete-reader adapter style:
//! construct a concrete adapter value first, then borrow its `Io.Reader`
//! interface via `ioReader()`.

const embed = @import("embed");
const testing_api = @import("testing");
const Io = embed.Io;

pub fn BufferedReader(comptime Reader: type) type {
    return struct {
        buffer_allocator: ?embed.mem.Allocator = null,
        rd: *Reader,
        read_err: ?anyerror = null,
        interface: Io.Reader,

        const Self = @This();

        fn initInterface(buffer: []u8) Io.Reader {
            return .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                    .rebase = rebase,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            };
        }

        /// `buf` must be non-empty.
        pub fn init(rd: *Reader, buf: []u8) Self {
            embed.debug.assert(buf.len > 0);
            return .{
                .rd = rd,
                .interface = initInterface(buf),
            };
        }

        pub fn initAlloc(rd: *Reader, allocator: embed.mem.Allocator, bufsize: usize) embed.mem.Allocator.Error!Self {
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
            embed.debug.assert(dest.len > 0);

            const n = readInto(self, dest) catch |read_err| switch (read_err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            r.end += n;

            // Reserve explicit headroom for delimiter-style scans so the next
            // fillMore() does not immediately re-enter with a full buffer.
            if (self.buffer_allocator != null and r.end == r.buffer.len) {
                try ensureManagedCapacity(self, r, r.buffer.len *| 2);
            }
        }

        fn ensureTailCapacity(self: *Self, r: *Io.Reader) Io.Reader.Error!void {
            if (r.end < r.buffer.len) return;

            if (self.buffer_allocator != null) {
                return ensureManagedCapacity(self, r, r.end - r.seek + 1);
            }

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

        fn rebase(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));
            const unread_len = r.end - r.seek;
            if (r.seek != 0 and unread_len != 0) {
                @memmove(r.buffer[0..unread_len], r.buffer[r.seek..r.end]);
            }
            r.seek = 0;
            r.end = unread_len;

            if (r.buffer.len >= capacity) return;
            if (self.buffer_allocator) |allocator| {
                const next_len = nextBufferLen(r.buffer.len, capacity);
                r.buffer = allocator.realloc(r.buffer, next_len) catch @panic("io.BufferedReader rebase out of memory");
                return;
            }

            embed.debug.assert(r.buffer.len >= capacity);
        }

        fn ensureManagedCapacity(self: *Self, r: *Io.Reader, capacity: usize) Io.Reader.Error!void {
            const allocator = self.buffer_allocator.?;
            const unread_len = r.end - r.seek;

            if (r.seek != 0 and unread_len != 0) {
                @memmove(r.buffer[0..unread_len], r.buffer[r.seek..r.end]);
            }
            r.seek = 0;
            r.end = unread_len;

            if (r.buffer.len >= capacity) return;

            const next_len = nextBufferLen(r.buffer.len, capacity);
            r.buffer = allocator.realloc(r.buffer, next_len) catch |alloc_err| {
                self.read_err = alloc_err;
                return error.ReadFailed;
            };
        }

        fn nextBufferLen(current_len: usize, required_len: usize) usize {
            var next_len = if (current_len == 0) @as(usize, 1) else current_len;
            while (next_len < required_len) {
                const doubled = next_len *| 2;
                if (doubled <= next_len) return required_len;
                next_len = doubled;
            }
            return next_len;
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
            if (Reader == Io.Reader) {
                return reader.readSliceShort(buf);
            }
            if (@hasDecl(Reader, "read")) {
                return reader.read(buf);
            }
            if (@hasDecl(Reader, "readSliceShort")) {
                return reader.readSliceShort(buf);
            }
            @compileError("io.BufferedReader requires a reader with read([]u8)!usize or embed.Io.Reader-compatible readSliceShort([]u8).");
        }
    };
}

pub fn BufferedWriter(comptime Writer: type) type {
    return struct {
        buffer_allocator: ?embed.mem.Allocator = null,
        wr: *Writer,
        write_err: ?anyerror = null,
        interface: Io.Writer,

        const Self = @This();

        fn initInterface(buffer: []u8) Io.Writer {
            return .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flushWriter,
                },
                .buffer = buffer,
            };
        }

        /// `buf` must be non-empty.
        pub fn init(wr: *Writer, buf: []u8) Self {
            embed.debug.assert(buf.len > 0);
            return .{
                .wr = wr,
                .interface = initInterface(buf),
            };
        }

        pub fn initAlloc(wr: *Writer, allocator: embed.mem.Allocator, bufsize: usize) embed.mem.Allocator.Error!Self {
            const buffer = try allocator.alloc(u8, @max(@as(usize, 1), bufsize));
            return .{
                .buffer_allocator = allocator,
                .wr = wr,
                .interface = initInterface(buffer),
            };
        }

        pub fn ioWriter(self: *Self) *Io.Writer {
            return &self.interface;
        }

        /// Returns the underlying write/flush failure after the `Io.Writer`
        /// surface reports `error.WriteFailed`.
        pub fn err(self: *const Self) ?anyerror {
            return self.write_err;
        }

        pub fn flush(self: *Self) Io.Writer.Error!void {
            return self.interface.flush();
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer_allocator) |allocator| {
                allocator.free(self.interface.buffer);
                self.buffer_allocator = null;
            }
        }

        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", w));
            embed.debug.assert(data.len > 0);

            try flushBuffered(self, w);

            const count = Io.Writer.countSplat(data, splat);
            if (count == 0) return 0;

            if (count <= w.buffer.len) {
                bufferComposite(w.buffer, data, splat);
                w.end = count;
                self.write_err = null;
                return count;
            }

            try writeCompositeAll(self, data, splat);
            return count;
        }

        fn flushWriter(w: *Io.Writer) Io.Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", w));
            while (w.end != 0) _ = try drain(w, &.{""}, 1);
            try flushUnderlying(self);
        }

        fn flushBuffered(self: *Self, w: *Io.Writer) Io.Writer.Error!void {
            var offset: usize = 0;
            while (offset < w.end) {
                const n = writeSome(self.wr, w.buffer[offset..w.end]) catch |write_err| {
                    self.write_err = write_err;
                    if (offset != 0) {
                        const remaining = w.end - offset;
                        @memmove(w.buffer[0..remaining], w.buffer[offset..w.end]);
                        w.end = remaining;
                    }
                    return error.WriteFailed;
                };
                if (n == 0) {
                    self.write_err = error.Unexpected;
                    if (offset != 0) {
                        const remaining = w.end - offset;
                        @memmove(w.buffer[0..remaining], w.buffer[offset..w.end]);
                        w.end = remaining;
                    }
                    return error.WriteFailed;
                }
                offset += n;
            }
            w.end = 0;
            self.write_err = null;
        }

        fn writeCompositeAll(self: *Self, data: []const []const u8, splat: usize) Io.Writer.Error!void {
            for (data[0 .. data.len - 1]) |bytes| {
                try writeAllInto(self, bytes);
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                try writeAllInto(self, pattern);
            }
        }

        fn bufferComposite(dst: []u8, data: []const []const u8, splat: usize) void {
            var used: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                @memcpy(dst[used..][0..bytes.len], bytes);
                used += bytes.len;
            }
            const pattern = data[data.len - 1];
            switch (pattern.len) {
                0 => {},
                1 => {
                    @memset(dst[used..][0..splat], pattern[0]);
                    used += splat;
                },
                else => for (0..splat) |_| {
                    @memcpy(dst[used..][0..pattern.len], pattern);
                    used += pattern.len;
                },
            }
        }

        fn writeAllInto(self: *Self, bytes: []const u8) Io.Writer.Error!void {
            var written: usize = 0;
            while (written < bytes.len) {
                const n = writeSome(self.wr, bytes[written..]) catch |write_err| {
                    self.write_err = write_err;
                    return error.WriteFailed;
                };
                if (n == 0) {
                    self.write_err = error.Unexpected;
                    return error.WriteFailed;
                }
                written += n;
            }
            self.write_err = null;
        }

        fn flushUnderlying(self: *Self) Io.Writer.Error!void {
            flushSome(self.wr) catch |flush_err| {
                self.write_err = flush_err;
                return error.WriteFailed;
            };
            self.write_err = null;
        }

        fn writeSome(writer: *Writer, buf: []const u8) anyerror!usize {
            if (Writer == Io.Writer) {
                return writer.write(buf);
            }
            if (@hasDecl(Writer, "write")) {
                return writer.write(buf);
            }
            @compileError("io.BufferedWriter requires a writer with write([]const u8)!usize or embed.Io.Writer-compatible write([]const u8).");
        }

        fn flushSome(writer: *Writer) anyerror!void {
            if (Writer == Io.Writer) {
                return writer.flush();
            }
            if (@hasDecl(Writer, "flush")) {
                return writer.flush();
            }
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn bufferedReaderInitAllocSupportsPeekAndTake(allocator: lib.mem.Allocator) !void {
            var src = Io.Reader.fixed("hello\r\nworld");
            var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, allocator, 1);
            defer br.deinit();
            const reader = br.ioReader();

            const peeked = try reader.peek(5);
            try lib.testing.expectEqualStrings("hello", peeked);
            try lib.testing.expect(reader.buffer.len >= 5);
            try lib.testing.expectEqualStrings("h", try reader.take(1));

            const rest = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("ello\r\n", rest);
        }

        fn bufferedReaderInitSupportsTextProtocolStyleReads() !void {
            var src = Io.Reader.fixed("PING a\r\nPONG b\r\n");
            var backing: [32]u8 = undefined;
            var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
            const reader = br.ioReader();

            const line1 = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("PING a\r\n", line1);

            const line2 = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("PONG b\r\n", line2);
        }

        fn bufferedReaderSmallBufferSupportsRebaseAcrossLines() !void {
            var src = Io.Reader.fixed("ab\r\ncd\r\n");
            var backing: [6]u8 = undefined;
            var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
            const reader = br.ioReader();

            const line1 = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("ab\r\n", line1);

            const line2 = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("cd\r\n", line2);
        }

        fn bufferedReaderInitReportsStreamTooLongForOverlongLine() !void {
            var src = Io.Reader.fixed("abcdX\n");
            var backing: [4]u8 = undefined;
            var br = BufferedReader(@TypeOf(src)).init(&src, &backing);

            try lib.testing.expectError(error.StreamTooLong, br.ioReader().takeDelimiterInclusive('\n'));
        }

        fn bufferedReaderInitAllocGrowsForExplicitPeekAndTake(allocator: lib.mem.Allocator) !void {
            var src = Io.Reader.fixed("abcdX\n");
            var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, allocator, 4);
            defer br.deinit();

            const line = try br.ioReader().peek(6);
            try lib.testing.expectEqualStrings("abcdX\n", line);
            try lib.testing.expectEqualStrings("abcdX\n", try br.ioReader().take(6));
            try lib.testing.expect(br.ioReader().buffer.len >= 6);
        }

        fn bufferedReaderInitAllocPeekGrowsAcrossShortThenLongLine(allocator: lib.mem.Allocator) !void {
            const long_body = [_]u8{'A'} ** 600;
            const input = "AT\r\n" ++ long_body ++ "\r\n";

            var src = Io.Reader.fixed(input);
            var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, allocator, 4);
            defer br.deinit();
            const reader = br.ioReader();

            const first = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqualStrings("AT\r\n", first);

            const second = try reader.peek(long_body.len + 2);
            try lib.testing.expectEqual(@as(usize, long_body.len + 2), second.len);
            try lib.testing.expect(second[0] == 'A');
            try lib.testing.expect(second[long_body.len - 1] == 'A');
            try lib.testing.expectEqualStrings("\r\n", second[long_body.len..]);
            try lib.testing.expectEqualStrings(second, try reader.take(long_body.len + 2));
            try lib.testing.expect(reader.buffer.len >= long_body.len + 2);
        }

        fn bufferedReaderInitAllocTakeDelimiterInclusiveGrowsAcrossShortThenLongLine(allocator: lib.mem.Allocator) !void {
            const long_body = [_]u8{'A'} ** 600;
            const input = "AT\r\n" ++ long_body ++ "\r\n";

            var src = Io.Reader.fixed(input);
            var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, allocator, 4);
            defer br.deinit();
            const reader = br.ioReader();

            try lib.testing.expectEqualStrings("AT\r\n", try reader.takeDelimiterInclusive('\n'));
            const second = try reader.takeDelimiterInclusive('\n');
            try lib.testing.expectEqual(@as(usize, long_body.len + 2), second.len);
            try lib.testing.expect(second[0] == 'A');
            try lib.testing.expect(second[long_body.len - 1] == 'A');
            try lib.testing.expectEqualStrings("\r\n", second[long_body.len..]);
        }

        fn bufferedReaderInitAllocZeroBufsizeStillReads(allocator: lib.mem.Allocator) !void {
            var src = Io.Reader.fixed("ok");
            var br = try BufferedReader(@TypeOf(src)).initAlloc(&src, allocator, 0);
            defer br.deinit();

            try lib.testing.expect(br.ioReader().buffer.len >= 1);
            try lib.testing.expectEqualStrings("o", try br.ioReader().take(1));
        }

        fn bufferedReaderErrPreservesAndClearsUnderlyingFailure() !void {
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

            try lib.testing.expectError(error.ReadFailed, reader.peek(1));
            try lib.testing.expect(br.err() != null);
            try lib.testing.expect(br.err().? == error.ConnectionReset);

            try lib.testing.expectEqualStrings("o", try reader.take(1));
            try lib.testing.expect(br.err() == null);
        }

        fn bufferedReaderReportsBufferTooSmallViaErrWhenWindowCannotGrow() !void {
            var src = Io.Reader.fixed("ab");
            var backing: [1]u8 = undefined;
            var br = BufferedReader(@TypeOf(src)).init(&src, &backing);
            const reader = br.ioReader();

            try lib.testing.expectEqualStrings("a", try reader.peek(1));

            var empty: [0]u8 = .{};
            var bufs = [_][]u8{&empty};
            try lib.testing.expectError(error.ReadFailed, @TypeOf(br).readVec(reader, &bufs));
            try lib.testing.expect(br.err() != null);
            try lib.testing.expect(br.err().? == error.BufferTooSmall);
        }

        fn bufferedWriterBuffersUntilFlush() !void {
            const Writer = struct {
                out: []u8,
                pos: usize = 0,

                fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [8]u8 = undefined;
            var sink = Writer{ .out = &storage };
            var backing: [8]u8 = undefined;
            var bw = BufferedWriter(Writer).init(&sink, &backing);
            const writer = bw.ioWriter();

            try writer.writeAll("hello");
            try lib.testing.expectEqual(@as(usize, 0), sink.pos);
            try lib.testing.expectEqualStrings("hello", writer.buffered());

            try bw.flush();
            try lib.testing.expectEqual(@as(usize, 5), sink.pos);
            try lib.testing.expectEqualStrings("hello", storage[0..5]);
            try lib.testing.expectEqual(@as(usize, 0), writer.buffered().len);
        }

        fn bufferedWriterLargeWriteDrainsDirectly() !void {
            const Writer = struct {
                out: []u8,
                pos: usize = 0,

                fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [16]u8 = undefined;
            var sink = Writer{ .out = &storage };
            var backing: [4]u8 = undefined;
            var bw = BufferedWriter(Writer).init(&sink, &backing);

            try bw.ioWriter().writeAll("abcdef");
            try lib.testing.expectEqualStrings("abcdef", storage[0..6]);
            try lib.testing.expectEqual(@as(usize, 0), bw.ioWriter().buffered().len);
        }

        fn bufferedWriterFlushPropagatesUnderlyingFlush() !void {
            const Writer = struct {
                out: []u8,
                pos: usize = 0,
                flush_count: usize = 0,

                fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }

                fn flush(self: *@This()) !void {
                    self.flush_count += 1;
                }
            };

            var storage: [8]u8 = undefined;
            var sink = Writer{ .out = &storage };
            var backing: [8]u8 = undefined;
            var bw = BufferedWriter(Writer).init(&sink, &backing);

            try bw.ioWriter().writeAll("ok");
            try bw.flush();
            try lib.testing.expectEqual(@as(usize, 1), sink.flush_count);
            try lib.testing.expectEqualStrings("ok", storage[0..2]);
        }

        fn bufferedWriterInitAllocZeroBufsizeStillWrites(allocator: lib.mem.Allocator) !void {
            const Writer = struct {
                out: []u8,
                pos: usize = 0,

                fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [4]u8 = undefined;
            var sink = Writer{ .out = &storage };
            var bw = try BufferedWriter(Writer).initAlloc(&sink, allocator, 0);
            defer bw.deinit();

            try lib.testing.expect(bw.ioWriter().buffer.len >= 1);
            try bw.ioWriter().writeAll("a");
            try bw.flush();
            try lib.testing.expectEqualStrings("a", storage[0..1]);
        }

        fn bufferedWriterErrPreservesRemainingBufferedBytes() !void {
            const Writer = struct {
                out: []u8,
                pos: usize = 0,
                call_count: usize = 0,

                fn write(self: *@This(), buf: []const u8) anyerror!usize {
                    self.call_count += 1;
                    return switch (self.call_count) {
                        1 => blk: {
                            self.out[self.pos] = buf[0];
                            self.pos += 1;
                            break :blk 1;
                        },
                        2 => error.ConnectionReset,
                        else => blk: {
                            @memcpy(self.out[self.pos..][0..buf.len], buf);
                            self.pos += buf.len;
                            break :blk buf.len;
                        },
                    };
                }
            };

            var storage: [8]u8 = undefined;
            var sink = Writer{ .out = &storage };
            var backing: [8]u8 = undefined;
            var bw = BufferedWriter(Writer).init(&sink, &backing);

            try bw.ioWriter().writeAll("ok");
            try lib.testing.expectError(error.WriteFailed, bw.flush());
            try lib.testing.expect(bw.err() != null);
            try lib.testing.expect(bw.err().? == error.ConnectionReset);
            try lib.testing.expectEqualStrings("k", bw.ioWriter().buffered());

            try bw.flush();
            try lib.testing.expect(bw.err() == null);
            try lib.testing.expectEqualStrings("ok", storage[0..2]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.bufferedReaderInitAllocSupportsPeekAndTake(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitSupportsTextProtocolStyleReads() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderSmallBufferSupportsRebaseAcrossLines() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitReportsStreamTooLongForOverlongLine() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitAllocGrowsForExplicitPeekAndTake(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitAllocPeekGrowsAcrossShortThenLongLine(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitAllocTakeDelimiterInclusiveGrowsAcrossShortThenLongLine(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderInitAllocZeroBufsizeStillReads(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderErrPreservesAndClearsUnderlyingFailure() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedReaderReportsBufferTooSmallViaErrWhenWindowCannotGrow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedWriterBuffersUntilFlush() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedWriterLargeWriteDrainsDirectly() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedWriterFlushPropagatesUnderlyingFlush() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedWriterInitAllocZeroBufsizeStillWrites(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.bufferedWriterErrPreservesRemainingBufferedBytes() catch |err| {
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
