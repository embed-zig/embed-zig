//! Reader — text protocol read-side helpers above `io.BufferedReader`.
//!
//! This file currently establishes the public shape of `net.textproto.Reader`
//! without committing to the full parsing implementation yet. The contract is
//! intentionally explicit about buffered-I/O ownership and zero-allocation-first
//! parsing.

const embed = @import("embed");
const io = @import("io");

pub fn Reader(comptime Buffered: type) type {
    validateBufferedType(Buffered);

    return struct {
        buffered: *Buffered,
        config: Config = .{},

        const Self = @This();
        const Io = embed.Io;

        pub const Config = struct {
            default_line_ending: LineEnding = .lf_or_crlf,
        };

        pub const LineEnding = enum {
            crlf_only,
            lf_or_crlf,
        };

        pub const ReadLineOptions = struct {
            line_ending: ?LineEnding = null,
            trim_ascii_space: bool = false,
        };

        pub const ReadContinuedLineOptions = struct {
            line: ReadLineOptions = .{},
        };

        pub const ReadHeaderBlockOptions = struct {
            line_ending: ?LineEnding = .crlf_only,
        };

        pub const ReadLineGroupOptions = struct {
            line: ReadLineOptions = .{},
            max_non_terminal_lines: usize = 256,
            terminal_ctx: ?*anyopaque = null,
            is_terminal: *const fn (ctx: ?*anyopaque, line: []const u8) bool,
            on_non_terminal_line_ctx: ?*anyopaque = null,
            on_non_terminal_line: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
        };

        pub const ReadCodeLineOptions = struct {
            line: ReadLineOptions = .{},
            expect_code: ?u16 = null,
        };

        pub const ReadResponseOptions = struct {
            line: ReadLineOptions = .{},
            expect_code: ?u16 = null,
            max_lines: usize = 256,
        };

        pub const LineGroupResult = struct {
            final_line: []const u8,
            non_terminal_lines: usize,
        };

        pub const CodeLine = struct {
            code: u16,
            message: []const u8,
        };

        pub const Response = struct {
            code: u16,
            message: []const u8,
            multiline: bool,
        };

        pub const ReadLineError = Io.Reader.Error || error{
            StreamTooLong,
            InvalidLineEnding,
            OutTooSmall,
        };

        pub const ReadContinuedLineError = ReadLineError || error{
            InvalidContinuation,
        };

        pub const ReadHeaderBlockError = ReadLineError;
        pub const ReadHeaderBlockAllocError = ReadHeaderBlockError || error{
            OutOfMemory,
        };

        pub const ReadLineGroupError = ReadLineError || error{
            TooManyNonTerminalLines,
        };

        pub const ReadCodeLineError = ReadLineError || error{
            InvalidCodeLine,
            UnexpectedCode,
            MultiLineResponse,
        };

        pub const ReadResponseError = ReadLineError || error{
            InvalidResponse,
            UnexpectedCode,
            TooManyLines,
        };

        pub const ReadDotError = Io.Reader.Error || error{
            StreamTooLong,
            InvalidDotEncoding,
        };

        pub const DotReader = struct {
            reader: *Self,
            pending_line: []const u8 = &.{},
            pending_offset: usize = 0,
            pending_newline: bool = false,
            done: bool = false,

            const DotSelf = @This();

            pub fn close(_: *DotSelf) void {}

            pub fn read(self: *DotSelf, buf: []u8) ReadDotError!usize {
                var written: usize = 0;
                while (written < buf.len) {
                    if (self.pending_offset < self.pending_line.len) {
                        const rest = self.pending_line[self.pending_offset..];
                        const n = @min(rest.len, buf.len - written);
                        @memcpy(buf[written..][0..n], rest[0..n]);
                        self.pending_offset += n;
                        written += n;
                        continue;
                    }

                    if (self.pending_newline) {
                        buf[written] = '\n';
                        self.pending_newline = false;
                        written += 1;
                        continue;
                    }

                    if (self.done) return written;

                    const raw = self.reader.takeRawLine() catch |err| return switch (err) {
                        error.EndOfStream => error.EndOfStream,
                        error.StreamTooLong => error.StreamTooLong,
                        error.ReadFailed => error.ReadFailed,
                    };
                    const body = self.reader.decodeBorrowedLine(raw, .{}) catch |err| return switch (err) {
                        error.InvalidLineEnding => error.InvalidDotEncoding,
                    };
                    if (body.len == 1 and body[0] == '.') {
                        self.done = true;
                        return written;
                    }

                    self.pending_line = if (body.len > 0 and body[0] == '.') body[1..] else body;
                    self.pending_offset = 0;
                    self.pending_newline = true;
                }
                return written;
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

        pub fn bufferedReader(self: *Self) *Buffered {
            return self.buffered;
        }

        pub fn ioReader(self: *Self) *Io.Reader {
            return self.buffered.ioReader();
        }

        /// Returns the underlying buffered-read failure after a parse method
        /// reports `error.ReadFailed`.
        pub fn underlyingErr(self: *const Self) ?anyerror {
            return self.buffered.err();
        }

        /// Reads one logical line into `out`, excluding the line terminator.
        ///
        /// The returned slice aliases `out`.
        pub fn readLine(self: *Self, out: []u8, options: ReadLineOptions) ReadLineError![]const u8 {
            const raw = try self.takeRawLine();
            const body = try self.decodeBorrowedLine(raw, options);
            if (body.len > out.len) return error.OutTooSmall;
            @memcpy(out[0..body.len], body);
            return out[0..body.len];
        }

        /// Reads a CRLF-style header section until the terminating blank line.
        ///
        /// The returned slice aliases `out`, preserves each header line's
        /// on-wire line ending, and excludes the final blank line terminator.
        pub fn readHeaderBlock(
            self: *Self,
            out: []u8,
            options: ReadHeaderBlockOptions,
        ) ReadHeaderBlockError![]const u8 {
            var used: usize = 0;
            while (true) {
                const raw = try self.takeRawLine();
                const line = try self.decodeBorrowedLine(raw, .{
                    .line_ending = options.line_ending,
                });
                if (line.len == 0) return out[0..used];
                if (used + raw.len > out.len) return error.OutTooSmall;
                @memcpy(out[used..][0..raw.len], raw);
                used += raw.len;
            }
        }

        /// Reads a CRLF-style header section into allocator-owned storage.
        ///
        /// The returned slice preserves each header line's on-wire line ending
        /// and excludes the final blank line terminator.
        pub fn readHeaderBlockAlloc(
            self: *Self,
            allocator: anytype,
            max_bytes: usize,
            options: ReadHeaderBlockOptions,
        ) ReadHeaderBlockAllocError![]u8 {
            const storage = try allocator.alloc(u8, max_bytes);
            errdefer allocator.free(storage);

            const head = try self.readHeaderBlock(storage, options);
            return try allocator.realloc(storage, head.len);
        }

        /// Reads one logical continued line, joining folded segments with one
        /// ASCII space.
        ///
        /// The returned slice aliases `out`.
        pub fn readContinuedLine(
            self: *Self,
            out: []u8,
            options: ReadContinuedLineOptions,
        ) ReadContinuedLineError![]const u8 {
            const first_raw = try self.takeRawLine();
            var used: usize = 0;
            const first = trimAsciiRight(try self.decodeBorrowedLine(first_raw, options.line));
            if (first.len > out.len) return error.OutTooSmall;
            @memcpy(out[0..first.len], first);
            used = first.len;

            while (true) {
                const next = self.ioReader().peek(1) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (next.len == 0 or (next[0] != ' ' and next[0] != '\t')) break;

                const raw = try self.takeRawLine();
                const decoded = try self.decodeBorrowedLine(raw, options.line);
                const segment = trimAscii(trimAsciiLeft(decoded));

                if (used != 0 and segment.len != 0) {
                    if (used == out.len) return error.OutTooSmall;
                    out[used] = ' ';
                    used += 1;
                }
                if (used + segment.len > out.len) return error.OutTooSmall;
                @memcpy(out[used..][0..segment.len], segment);
                used += segment.len;
            }

            return out[0..used];
        }

        /// Reads ordinary lines until `is_terminal` reports the final line.
        ///
        /// Non-terminal lines are streamed through `on_non_terminal_line` when
        /// provided. The returned final-line slice aliases `out`.
        pub fn readLineGroup(
            self: *Self,
            out: []u8,
            options: ReadLineGroupOptions,
        ) ReadLineGroupError!LineGroupResult {
            var non_terminal_lines: usize = 0;
            while (true) {
                const line = try self.readLine(out, options.line);
                if (options.is_terminal(options.terminal_ctx, line)) {
                    return .{
                        .final_line = line,
                        .non_terminal_lines = non_terminal_lines,
                    };
                }
                if (non_terminal_lines >= options.max_non_terminal_lines) {
                    return error.TooManyNonTerminalLines;
                }
                non_terminal_lines += 1;
                if (options.on_non_terminal_line) |cb| {
                    cb(options.on_non_terminal_line_ctx, line);
                }
            }
        }

        /// Reads exactly one numeric status line of the form `XYZ message`.
        ///
        /// The returned `message` slice aliases `line_buf`.
        pub fn readCodeLine(
            self: *Self,
            line_buf: []u8,
            options: ReadCodeLineOptions,
        ) ReadCodeLineError!CodeLine {
            const line = try self.readLine(line_buf, options.line);
            const parsed = parseCodePrefix(line, true) catch |err| switch (err) {
                error.InvalidCodeLine => return error.InvalidCodeLine,
                error.MultiLineResponse => return error.MultiLineResponse,
                error.InvalidResponse => return error.InvalidCodeLine,
            };
            if (parsed.separator == '-') return error.MultiLineResponse;
            if (options.expect_code) |expected| {
                if (parsed.code != expected) return error.UnexpectedCode;
            }
            return .{
                .code = parsed.code,
                .message = parsed.message,
            };
        }

        /// Reads a Go-style numeric response block, joining message lines into
        /// `message_buf` with `\n`.
        pub fn readResponse(
            self: *Self,
            line_buf: []u8,
            message_buf: []u8,
            options: ReadResponseOptions,
        ) ReadResponseError!Response {
            const first_line = try self.readLine(line_buf, options.line);
            const first = parseCodePrefix(first_line, false) catch |err| switch (err) {
                error.InvalidResponse, error.InvalidCodeLine, error.MultiLineResponse => return error.InvalidResponse,
            };
            if (options.expect_code) |expected| {
                if (first.code != expected) return error.UnexpectedCode;
            }

            var used: usize = 0;
            var line_count: usize = 0;
            used = try appendMessageLine(message_buf, used, first.message, &line_count, options.max_lines);

            if (first.separator != '-') {
                return .{
                    .code = first.code,
                    .message = message_buf[0..used],
                    .multiline = false,
                };
            }

            while (true) {
                const line = try self.readLine(line_buf, options.line);
                if (isFinalResponseLine(line, first.code)) {
                    const last = line[4..];
                    used = try appendMessageLine(message_buf, used, last, &line_count, options.max_lines);
                    return .{
                        .code = first.code,
                        .message = message_buf[0..used],
                        .multiline = true,
                    };
                }

                const segment = if (hasSameCodeContinuation(line, first.code)) line[4..] else line;
                used = try appendMessageLine(message_buf, used, segment, &line_count, options.max_lines);
            }
        }

        /// Returns a streaming dot-decoder view over the current reader.
        pub fn dotReader(self: *Self) DotReader {
            return .{ .reader = self };
        }

        fn takeRawLine(self: *Self) (Io.Reader.Error || error{StreamTooLong})![]const u8 {
            return self.ioReader().takeDelimiterInclusive('\n');
        }

        fn decodeBorrowedLine(self: *Self, raw: []const u8, options: ReadLineOptions) error{InvalidLineEnding}![]const u8 {
            if (raw.len == 0 or raw[raw.len - 1] != '\n') return error.InvalidLineEnding;

            const effective = options.line_ending orelse self.config.default_line_ending;
            var body = raw[0 .. raw.len - 1];
            switch (effective) {
                .crlf_only => {
                    if (body.len == 0 or body[body.len - 1] != '\r') return error.InvalidLineEnding;
                    body = body[0 .. body.len - 1];
                },
                .lf_or_crlf => {
                    if (body.len > 0 and body[body.len - 1] == '\r') {
                        body = body[0 .. body.len - 1];
                    }
                },
            }

            body = if (options.trim_ascii_space) trimAscii(body) else body;
            return body;
        }
    };
}

fn parseCodePrefix(line: []const u8, require_space_separator: bool) error{ InvalidCodeLine, InvalidResponse, MultiLineResponse }!struct {
    code: u16,
    separator: u8,
    message: []const u8,
} {
    if (line.len < 3) return if (require_space_separator) error.InvalidCodeLine else error.InvalidResponse;
    if (!isDigit(line[0]) or !isDigit(line[1]) or !isDigit(line[2])) {
        return if (require_space_separator) error.InvalidCodeLine else error.InvalidResponse;
    }

    const code: u16 = @as(u16, line[0] - '0') * 100 + @as(u16, line[1] - '0') * 10 + @as(u16, line[2] - '0');
    if (line.len == 3) {
        return .{
            .code = code,
            .separator = ' ',
            .message = "",
        };
    }

    const separator = line[3];
    if (separator == '-') {
        if (require_space_separator) return error.MultiLineResponse;
        return .{
            .code = code,
            .separator = separator,
            .message = line[4..],
        };
    }
    if (separator != ' ') {
        return if (require_space_separator) error.InvalidCodeLine else error.InvalidResponse;
    }
    return .{
        .code = code,
        .separator = separator,
        .message = line[4..],
    };
}

fn appendMessageLine(
    out: []u8,
    used: usize,
    line: []const u8,
    line_count: *usize,
    max_lines: usize,
) error{ OutTooSmall, TooManyLines }!usize {
    if (line_count.* >= max_lines) return error.TooManyLines;
    var next_used = used;
    if (line_count.* > 0) {
        if (next_used == out.len) return error.OutTooSmall;
        out[next_used] = '\n';
        next_used += 1;
    }
    if (next_used + line.len > out.len) return error.OutTooSmall;
    @memcpy(out[next_used..][0..line.len], line);
    next_used += line.len;
    line_count.* += 1;
    return next_used;
}

fn isFinalResponseLine(line: []const u8, code: u16) bool {
    return line.len >= 4 and
        sameCode(line, code) and
        line[3] == ' ';
}

fn hasSameCodeContinuation(line: []const u8, code: u16) bool {
    return line.len >= 4 and
        sameCode(line, code) and
        line[3] == '-';
}

fn sameCode(line: []const u8, code: u16) bool {
    if (line.len < 3) return false;
    const hundreds: u8 = @intCast(code / 100);
    const tens: u8 = @intCast((code / 10) % 10);
    const ones: u8 = @intCast(code % 10);
    return line[0] == '0' + hundreds and
        line[1] == '0' + tens and
        line[2] == '0' + ones;
}

fn trimAscii(slice: []const u8) []const u8 {
    return trimAsciiRight(trimAsciiLeft(slice));
}

fn trimAsciiLeft(slice: []const u8) []const u8 {
    var start: usize = 0;
    while (start < slice.len and (slice[start] == ' ' or slice[start] == '\t')) start += 1;
    return slice[start..];
}

fn trimAsciiRight(slice: []const u8) []const u8 {
    var end = slice.len;
    while (end > 0 and (slice[end - 1] == ' ' or slice[end - 1] == '\t')) end -= 1;
    return slice[0..end];
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn validateBufferedType(comptime Buffered: type) void {
    if (!@hasDecl(Buffered, "ioReader")) {
        @compileError("textproto.Reader expects a buffered reader type with ioReader().");
    }
    if (!@hasDecl(Buffered, "err")) {
        @compileError("textproto.Reader expects a buffered reader type with err().");
    }
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    const TestCase = struct {
        fn expectError(comptime expected: anyerror, actual: anytype) !void {
            if (actual) |_| {
                return error.ExpectedErrorNotReturned;
            } else |err| {
                try lib.testing.expect(err == expected);
            }
        }

        fn readAllDot(dot: anytype, out: []u8) ![]const u8 {
            var used: usize = 0;
            var scratch: [2]u8 = undefined;
            while (true) {
                const n = try dot.read(&scratch);
                if (n == 0) break;
                if (used + n > out.len) return error.OutTooSmall;
                @memcpy(out[used..][0..n], scratch[0..n]);
                used += n;
            }
            return out[0..used];
        }

        fn readerInitShapes(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Io = embed.Io;

            {
                var src = Io.Reader.fixed("PING a\r\n");
                var backing: [32]u8 = undefined;
                const BufferedReader = io.BufferedReader(@TypeOf(src));
                const TpReader = Reader(BufferedReader);
                var buffered = BufferedReader.init(&src, &backing);

                var reader = TpReader.init(&buffered, .{});

                try testing.expectEqual(@as(usize, backing.len), reader.ioReader().buffer.len);
                try testing.expect(reader.underlyingErr() == null);
                try testing.expect(reader.bufferedReader().ioReader() == reader.ioReader());
            }

            {
                var src = Io.Reader.fixed("PONG b\r\n");
                var backing: [16]u8 = undefined;
                const BufferedReader = io.BufferedReader(@TypeOf(src));
                const TpReader = Reader(BufferedReader);
                var buffered = BufferedReader.init(&src, &backing);

                var reader = TpReader.fromBuffered(&buffered);
                defer reader.deinit();

                try testing.expectEqual(TpReader.LineEnding.lf_or_crlf, reader.config.default_line_ending);
                try testing.expect(reader.underlyingErr() == null);
            }

            {
                var src = Io.Reader.fixed("OK\r\n");
                const BufferedReader = io.BufferedReader(@TypeOf(src));
                const TpReader = Reader(BufferedReader);
                var buffered = try BufferedReader.initAlloc(&src, allocator, 8);
                defer buffered.deinit();

                var reader = TpReader.init(&buffered, .{ .default_line_ending = .crlf_only });
                defer reader.deinit();

                try testing.expect(reader.ioReader().buffer.len >= 1);
                try testing.expectEqual(TpReader.LineEnding.crlf_only, reader.config.default_line_ending);
            }
        }

        fn readLineTrimsCrlf() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            const line = try reader.readLine(&out, .{});
            try testing.expectEqualStrings("PING a", line);
        }

        fn readLineTrimsLf() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            const line = try reader.readLine(&out, .{});
            try testing.expectEqualStrings("PING a", line);
        }

        fn readLineTrimAsciiSpace() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("  PING a \t\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            const line = try reader.readLine(&out, .{ .trim_ascii_space = true });
            try testing.expectEqualStrings("PING a", line);
        }

        fn readLineRejectsLfWhenCrlfOnly() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.init(&buffered, .{ .default_line_ending = .crlf_only });

            var out: [32]u8 = undefined;
            try expectError(error.InvalidLineEnding, reader.readLine(&out, .{}));
        }

        fn readLineOutTooSmall() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [4]u8 = undefined;
            try expectError(error.OutTooSmall, reader.readLine(&out, .{}));
        }

        fn readContinuedLineJoinsFoldedSegments() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("hello\r\n world\r\n\tzig \t\r\nnext\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [64]u8 = undefined;
            const logical = try reader.readContinuedLine(&out, .{});
            try testing.expectEqualStrings("hello world zig", logical);

            const next = try reader.readLine(&out, .{});
            try testing.expectEqualStrings("next", next);
        }

        fn readHeaderBlockCollectsCrlfLines() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\r\nUser-Agent: zig\r\n\r\nNEXT\r\n");
            var backing: [96]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [96]u8 = undefined;
            const head = try reader.readHeaderBlock(&out, .{});
            try testing.expectEqualStrings("Host: example.com\r\nUser-Agent: zig\r\n", head);

            var next_out: [16]u8 = undefined;
            const next = try reader.readLine(&next_out, .{});
            try testing.expectEqualStrings("NEXT", next);
        }

        fn readHeaderBlockAllowsEmptySection() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("\r\nNEXT\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            const head = try reader.readHeaderBlock(&out, .{});
            try testing.expectEqual(@as(usize, 0), head.len);
        }

        fn readHeaderBlockRejectsLfWhenCrlfOnly() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\n\n");
            var backing: [48]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [48]u8 = undefined;
            try expectError(error.InvalidLineEnding, reader.readHeaderBlock(&out, .{}));
        }

        fn readHeaderBlockOutTooSmall() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\r\n\r\n");
            var backing: [48]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [8]u8 = undefined;
            try expectError(error.OutTooSmall, reader.readHeaderBlock(&out, .{}));
        }

        fn readHeaderBlockAllocReturnsOwnedSlice(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\r\nUser-Agent: zig\r\n\r\nNEXT\r\n");
            var backing: [96]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            const head = try reader.readHeaderBlockAlloc(allocator, 96, .{});
            defer allocator.free(head);
            try testing.expectEqualStrings("Host: example.com\r\nUser-Agent: zig\r\n", head);

            var next_out: [16]u8 = undefined;
            const next = try reader.readLine(&next_out, .{});
            try testing.expectEqualStrings("NEXT", next);
        }

        fn readLineGroupStopsOnTerminalLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            const Ctx = struct {
                count: usize = 0,
                fn isTerminal(_: ?*anyopaque, line: []const u8) bool {
                    return embed.mem.eql(u8, line, "OK");
                }
                fn onInfo(ctx: ?*anyopaque, line: []const u8) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    self.count += 1;
                    switch (self.count) {
                        1 => testing.expectEqualStrings("INFO 1", line) catch unreachable,
                        2 => testing.expectEqualStrings("INFO 2", line) catch unreachable,
                        else => unreachable,
                    }
                }
            };

            var src = Io.Reader.fixed("INFO 1\r\nINFO 2\r\nOK\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            var ctx = Ctx{};
            const result = try reader.readLineGroup(&out, .{
                .terminal_ctx = null,
                .is_terminal = Ctx.isTerminal,
                .on_non_terminal_line_ctx = @ptrCast(&ctx),
                .on_non_terminal_line = Ctx.onInfo,
            });

            try testing.expectEqualStrings("OK", result.final_line);
            try testing.expectEqual(@as(usize, 2), result.non_terminal_lines);
            try testing.expectEqual(@as(usize, 2), ctx.count);
        }

        fn readLineGroupRespectsNonTerminalLimit() !void {
            const Io = embed.Io;

            const Cb = struct {
                fn isTerminal(_: ?*anyopaque, line: []const u8) bool {
                    return embed.mem.eql(u8, line, "OK");
                }
            };

            var src = Io.Reader.fixed("INFO 1\r\nINFO 2\r\nOK\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var out: [32]u8 = undefined;
            try expectError(error.TooManyNonTerminalLines, reader.readLineGroup(&out, .{
                .max_non_terminal_lines = 1,
                .is_terminal = Cb.isTerminal,
            }));
        }

        fn readCodeLineParsesSingleLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("220 smtp.example\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            const result = try reader.readCodeLine(&line_buf, .{ .expect_code = 220 });
            try testing.expectEqual(@as(u16, 220), result.code);
            try testing.expectEqualStrings("smtp.example", result.message);
        }

        fn readCodeLineRejectsUnexpectedCode() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("421 unavailable\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            try expectError(error.UnexpectedCode, reader.readCodeLine(&line_buf, .{ .expect_code = 220 }));
        }

        fn readCodeLineRejectsMultilineForm() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("220-smtp.example\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            try expectError(error.MultiLineResponse, reader.readCodeLine(&line_buf, .{}));
        }

        fn readResponseParsesSingleLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("250 ok\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            var message_buf: [64]u8 = undefined;
            const result = try reader.readResponse(&line_buf, &message_buf, .{ .expect_code = 250 });
            try testing.expectEqual(@as(u16, 250), result.code);
            try testing.expectEqualStrings("ok", result.message);
            try testing.expect(!result.multiline);
        }

        fn readResponseParsesMultilineBlock() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("250-first line\r\nsecond line\r\n250 third line\r\n");
            var backing: [128]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            var message_buf: [128]u8 = undefined;
            const result = try reader.readResponse(&line_buf, &message_buf, .{ .expect_code = 250 });
            try testing.expectEqual(@as(u16, 250), result.code);
            try testing.expectEqualStrings("first line\nsecond line\nthird line", result.message);
            try testing.expect(result.multiline);
        }

        fn readResponseRejectsUnexpectedCode() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("550 denied\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            var message_buf: [64]u8 = undefined;
            try expectError(error.UnexpectedCode, reader.readResponse(&line_buf, &message_buf, .{ .expect_code = 250 }));
        }

        fn readResponseRespectsMaxLines() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("250-first\r\nsecond\r\n250 third\r\n");
            var backing: [128]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var line_buf: [64]u8 = undefined;
            var message_buf: [128]u8 = undefined;
            try expectError(error.TooManyLines, reader.readResponse(&line_buf, &message_buf, .{
                .max_lines = 2,
            }));
        }

        fn dotReaderUnstuffsAndLeavesFollowingLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("alpha\r\n..beta\r\n.\r\nNEXT\r\n");
            var backing: [128]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);

            var dot = reader.dotReader();
            var dot_out: [64]u8 = undefined;
            const body = try readAllDot(&dot, &dot_out);
            try testing.expectEqualStrings("alpha\n.beta\n", body);

            var line_out: [32]u8 = undefined;
            const next = try reader.readLine(&line_out, .{});
            try testing.expectEqualStrings("NEXT", next);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.readerInitShapes(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readHeaderBlockAllocReturnsOwnedSlice(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            inline for (.{
                TestCase.readLineTrimsCrlf,
                TestCase.readLineTrimsLf,
                TestCase.readLineTrimAsciiSpace,
                TestCase.readLineRejectsLfWhenCrlfOnly,
                TestCase.readLineOutTooSmall,
                TestCase.readContinuedLineJoinsFoldedSegments,
                TestCase.readHeaderBlockCollectsCrlfLines,
                TestCase.readHeaderBlockAllowsEmptySection,
                TestCase.readHeaderBlockRejectsLfWhenCrlfOnly,
                TestCase.readHeaderBlockOutTooSmall,
                TestCase.readLineGroupStopsOnTerminalLine,
                TestCase.readLineGroupRespectsNonTerminalLimit,
                TestCase.readCodeLineParsesSingleLine,
                TestCase.readCodeLineRejectsUnexpectedCode,
                TestCase.readCodeLineRejectsMultilineForm,
                TestCase.readResponseParsesSingleLine,
                TestCase.readResponseParsesMultilineBlock,
                TestCase.readResponseRejectsUnexpectedCode,
                TestCase.readResponseRespectsMaxLines,
                TestCase.dotReaderUnstuffsAndLeavesFollowingLine,
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
