//! Writer — text protocol write-side helpers above `io.BufferedWriter`.
//!
//! This file establishes the public shape of `net.textproto.Writer` while
//! keeping buffering ownership in `lib/io`.

const stdz = @import("stdz");
const io = @import("io");

pub fn Writer(comptime Buffered: type) type {
    validateBufferedType(Buffered);

    return struct {
        buffered: *Buffered,
        config: Config = .{},

        const Self = @This();
        const Io = stdz.Io;

        pub const Config = struct {};

        pub const WriteLineError = Io.Writer.Error || error{
            InvalidLine,
        };

        pub const WriteDotError = Io.Writer.Error || error{
            Closed,
        };

        pub const DotWriter = struct {
            writer: *Self,
            line_start: bool = true,
            prev_was_cr: bool = false,
            closed: bool = false,

            const DotSelf = @This();

            pub fn write(self: *DotSelf, buf: []const u8) WriteDotError!usize {
                if (self.closed) return error.Closed;

                for (buf) |ch| {
                    if (self.line_start and ch == '.') {
                        try self.writer.ioWriter().writeAll(".");
                    }

                    if (ch == '\n') {
                        if (!self.prev_was_cr) try self.writer.ioWriter().writeAll("\r");
                        try self.writer.ioWriter().writeAll("\n");
                        self.line_start = true;
                        self.prev_was_cr = false;
                        continue;
                    }

                    try writeByte(self.writer.ioWriter(), ch);
                    self.line_start = false;
                    self.prev_was_cr = ch == '\r';
                }

                return buf.len;
            }

            pub fn close(self: *DotSelf) WriteDotError!void {
                if (self.closed) return;

                if (!self.line_start) {
                    try self.writer.ioWriter().writeAll(if (self.prev_was_cr) "\n" else "\r\n");
                }
                try self.writer.ioWriter().writeAll(".\r\n");

                self.closed = true;
                self.line_start = true;
                self.prev_was_cr = false;
            }
        };

        pub fn init(buffered: *Buffered, config: Config) Self {
            return .{
                .buffered = buffered,
                .config = config,
            };
        }

        pub fn fromBuffered(buffered: *Buffered) Self {
            return Self.init(buffered, .{});
        }

        pub fn deinit(_: *Self) void {}

        pub fn bufferedWriter(self: *Self) *Buffered {
            return self.buffered;
        }

        pub fn ioWriter(self: *Self) *Io.Writer {
            return self.buffered.ioWriter();
        }

        /// Returns the underlying buffered-write failure after a write method
        /// reports `error.WriteFailed`.
        pub fn underlyingErr(self: *const Self) ?anyerror {
            return self.buffered.err();
        }

        pub fn flush(self: *Self) Io.Writer.Error!void {
            return self.ioWriter().flush();
        }

        /// Writes one logical line followed by `\r\n`.
        pub fn writeLine(self: *Self, line: []const u8) WriteLineError!void {
            try validateLinePart(line);

            try self.ioWriter().writeAll(line);
            try self.ioWriter().writeAll("\r\n");
        }

        /// Writes one logical line from multiple parts followed by `\r\n`.
        pub fn writeLineParts(self: *Self, parts: []const []const u8) WriteLineError!void {
            for (parts) |part| {
                try validateLinePart(part);
                try self.ioWriter().writeAll(part);
            }
            try self.ioWriter().writeAll("\r\n");
        }

        /// Returns a streaming dot-encoder view over the current writer.
        pub fn dotWriter(self: *Self) DotWriter {
            return .{ .writer = self };
        }
    };
}

fn writeByte(writer: *stdz.Io.Writer, byte: u8) stdz.Io.Writer.Error!void {
    const buf = [1]u8{byte};
    try writer.writeAll(&buf);
}

fn validateLinePart(part: []const u8) error{InvalidLine}!void {
    for (part) |ch| {
        if (ch == '\r' or ch == '\n') return error.InvalidLine;
    }
}

fn validateBufferedType(comptime Buffered: type) void {
    if (!@hasDecl(Buffered, "ioWriter")) {
        @compileError("textproto.Writer expects a buffered writer type with ioWriter().");
    }
    if (!@hasDecl(Buffered, "err")) {
        @compileError("textproto.Writer expects a buffered writer type with err().");
    }
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn writerInitShapes(allocator: lib.mem.Allocator) !void {
            const Sink = struct {
                out: []u8,
                pos: usize = 0,

                pub fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            {
                var storage: [8]u8 = undefined;
                var sink = Sink{ .out = &storage };
                var backing: [8]u8 = undefined;
                const BufferedWriter = io.BufferedWriter(Sink);
                const TpWriter = Writer(BufferedWriter);
                var buffered = BufferedWriter.init(&sink, &backing);

                var writer = TpWriter.init(&buffered, .{});
                try lib.testing.expectEqual(@as(usize, backing.len), writer.ioWriter().buffer.len);
                try lib.testing.expect(writer.underlyingErr() == null);
                try lib.testing.expect(writer.bufferedWriter().ioWriter() == writer.ioWriter());
            }

            {
                var storage: [8]u8 = undefined;
                var sink = Sink{ .out = &storage };
                const BufferedWriter = io.BufferedWriter(Sink);
                const TpWriter = Writer(BufferedWriter);
                var buffered = try BufferedWriter.initAlloc(&sink, allocator, 8);
                defer buffered.deinit();

                var writer = TpWriter.fromBuffered(&buffered);
                defer writer.deinit();
                try lib.testing.expect(writer.ioWriter().buffer.len >= 1);
                try lib.testing.expect(writer.underlyingErr() == null);
            }
        }

        fn writeLineAppendsCrlf() !void {
            const Sink = struct {
                out: []u8,
                pos: usize = 0,

                pub fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [16]u8 = undefined;
            var sink = Sink{ .out = &storage };
            var backing: [16]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);

            try writer.writeLine("PING a");
            try lib.testing.expectEqual(@as(usize, 0), sink.pos);
            try lib.testing.expectEqualStrings("PING a\r\n", writer.ioWriter().buffered());

            try writer.flush();
            try lib.testing.expectEqualStrings("PING a\r\n", storage[0..8]);
        }

        fn writeLineRejectsEmbeddedNewline() !void {
            const Sink = struct {
                pub fn write(_: *@This(), _: []const u8) !usize {
                    unreachable;
                }
            };

            var sink = Sink{};
            var backing: [8]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);

            try lib.testing.expectError(error.InvalidLine, writer.writeLine("bad\nline"));
            try lib.testing.expectError(error.InvalidLine, writer.writeLine("bad\rline"));
        }

        fn writeLinePartsAppendsCrlf() !void {
            const Sink = struct {
                out: []u8,
                pos: usize = 0,

                pub fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [32]u8 = undefined;
            var sink = Sink{ .out = &storage };
            var backing: [32]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);

            try writer.writeLineParts(&.{ "PING", " ", "a" });
            try writer.flush();

            try lib.testing.expectEqualStrings("PING a\r\n", storage[0..8]);
        }

        fn writeLinePartsRejectsEmbeddedNewline() !void {
            const Sink = struct {
                pub fn write(_: *@This(), _: []const u8) !usize {
                    unreachable;
                }
            };

            var sink = Sink{};
            var backing: [8]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);

            try lib.testing.expectError(error.InvalidLine, writer.writeLineParts(&.{ "bad", "\nline" }));
            try lib.testing.expectError(error.InvalidLine, writer.writeLineParts(&.{ "bad\r", "line" }));
        }

        fn writeLineExposesUnderlyingError() !void {
            const Sink = struct {
                fail_once: bool = true,

                pub fn write(self: *@This(), _: []const u8) anyerror!usize {
                    if (self.fail_once) {
                        self.fail_once = false;
                        return error.ConnectionReset;
                    }
                    unreachable;
                }
            };

            var sink = Sink{};
            var backing: [1]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);

            try lib.testing.expectError(error.WriteFailed, writer.writeLine("ab"));
            try lib.testing.expect(writer.underlyingErr() != null);
            try lib.testing.expect(writer.underlyingErr().? == error.ConnectionReset);
        }

        fn dotWriterStuffsNormalizesAndTerminates() !void {
            const Sink = struct {
                out: []u8,
                pos: usize = 0,

                pub fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [64]u8 = undefined;
            var sink = Sink{ .out = &storage };
            var backing: [64]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);
            var dot = writer.dotWriter();

            try lib.testing.expectEqual(@as(usize, 12), try dot.write("alpha\n.beta\n"));
            try dot.close();
            try writer.flush();

            try lib.testing.expectEqualStrings("alpha\r\n..beta\r\n.\r\n", storage[0..18]);
        }

        fn dotWriterTracksCrLfAcrossWrites() !void {
            const Sink = struct {
                out: []u8,
                pos: usize = 0,

                pub fn write(self: *@This(), buf: []const u8) !usize {
                    @memcpy(self.out[self.pos..][0..buf.len], buf);
                    self.pos += buf.len;
                    return buf.len;
                }
            };

            var storage: [64]u8 = undefined;
            var sink = Sink{ .out = &storage };
            var backing: [64]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);
            var dot = writer.dotWriter();

            try lib.testing.expectEqual(@as(usize, 6), try dot.write("alpha\r"));
            try lib.testing.expectEqual(@as(usize, 6), try dot.write("\n.beta"));
            try dot.close();
            try writer.flush();

            try lib.testing.expectEqualStrings("alpha\r\n..beta\r\n.\r\n", storage[0..18]);
        }

        fn dotWriterRejectsWriteAfterClose() !void {
            const Sink = struct {
                pub fn write(_: *@This(), buf: []const u8) !usize {
                    return buf.len;
                }
            };

            var sink = Sink{};
            var backing: [16]u8 = undefined;
            const BufferedWriter = io.BufferedWriter(Sink);
            const TpWriter = Writer(BufferedWriter);
            var buffered = BufferedWriter.init(&sink, &backing);
            var writer = TpWriter.fromBuffered(&buffered);
            var dot = writer.dotWriter();

            try dot.close();
            try lib.testing.expectError(error.Closed, dot.write("x"));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.writerInitShapes(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            inline for (.{
                TestCase.writeLineAppendsCrlf,
                TestCase.writeLineRejectsEmbeddedNewline,
                TestCase.writeLinePartsAppendsCrlf,
                TestCase.writeLinePartsRejectsEmbeddedNewline,
                TestCase.writeLineExposesUnderlyingError,
                TestCase.dotWriterStuffsNormalizesAndTerminates,
                TestCase.dotWriterTracksCrLfAcrossWrites,
                TestCase.dotWriterRejectsWriteAfterClose,
            }) |case_fn| {
                case_fn() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
