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
            raw: []const u8,
            multiline: bool,
        };

        pub const ReadLineError = Io.Reader.Error || error{
            StreamTooLong,
            InvalidLineEnding,
        };

        pub const ReadContinuedLineError = ReadLineError || error{
            InvalidContinuation,
        };

        pub const ReadHeaderBlockError = ReadLineError;
        pub const ReadHeaderBlockMaxError = ReadHeaderBlockError || error{
            BufferTooSmall,
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

        /// Takes one logical line, excluding the line terminator.
        ///
        /// The returned slice aliases the underlying `Io.Reader` buffer.
        pub fn takeLine(self: *Self, options: ReadLineOptions) ReadLineError![]const u8 {
            const raw = try self.takeRawLine();
            return try self.decodeBorrowedLine(raw, options);
        }

        /// Takes a CRLF-style header section until the terminating blank line.
        ///
        /// The returned slice aliases the underlying `Io.Reader` buffer,
        /// preserves each header line's on-wire line ending, and excludes the
        /// final blank line terminator.
        pub fn takeHeaderBlock(self: *Self, options: ReadHeaderBlockOptions) ReadHeaderBlockError![]const u8 {
            const scanned = try self.scanHeaderBlock(options);
            const block = if (scanned.content_len == 0) &.{} else try self.ioReader().take(scanned.content_len);
            _ = try self.ioReader().take(scanned.terminator_len);
            return block;
        }

        /// Takes a CRLF-style header section with an explicit byte ceiling.
        ///
        /// The returned slice aliases the underlying `Io.Reader` buffer,
        /// preserves each header line's on-wire line ending, and excludes the
        /// final blank line terminator.
        pub fn takeHeaderBlockMax(self: *Self, max_bytes: usize, options: ReadHeaderBlockOptions) ReadHeaderBlockMaxError![]const u8 {
            const scanned = try self.scanHeaderBlockMax(max_bytes, options);
            const block = if (scanned.content_len == 0) &.{} else try self.ioReader().take(scanned.content_len);
            _ = try self.ioReader().take(scanned.terminator_len);
            return block;
        }

        /// Takes one logical continued line block, preserving the on-wire bytes
        /// of the first line and each folded continuation line.
        ///
        /// The returned slice aliases the underlying `Io.Reader` buffer.
        pub fn takeContinuedLine(self: *Self, options: ReadContinuedLineOptions) ReadContinuedLineError![]const u8 {
            const total_len = try self.scanContinuedLineLen(options);
            return try self.ioReader().take(total_len);
        }

        /// Reads ordinary lines until `is_terminal` reports the final line.
        ///
        /// Non-terminal lines are streamed through `on_non_terminal_line` when
        /// provided. The returned final-line slice aliases the underlying
        /// `Io.Reader` buffer.
        pub fn takeLineGroup(self: *Self, options: ReadLineGroupOptions) ReadLineGroupError!LineGroupResult {
            var non_terminal_lines: usize = 0;
            while (true) {
                const line = try self.takeLine(options.line);
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
        /// The returned `message` slice aliases the underlying `Io.Reader` buffer.
        pub fn takeCodeLine(self: *Self, options: ReadCodeLineOptions) ReadCodeLineError!CodeLine {
            const line = try self.takeLine(options.line);
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

        /// Takes a Go-style numeric response block and returns the raw on-wire
        /// bytes for the full response.
        pub fn takeResponse(self: *Self, options: ReadResponseOptions) ReadResponseError!Response {
            const scanned = try self.scanResponseBlock(options);
            return .{
                .code = scanned.code,
                .raw = try self.ioReader().take(scanned.total_len),
                .multiline = scanned.multiline,
            };
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

        fn scanHeaderBlock(self: *Self, options: ReadHeaderBlockOptions) ReadHeaderBlockError!struct {
            content_len: usize,
            terminator_len: usize,
        } {
            var offset: usize = 0;
            while (true) {
                const raw = try self.peekRawLineAt(offset);
                const line = try self.decodeBorrowedLine(raw, .{
                    .line_ending = options.line_ending,
                });
                if (line.len == 0) {
                    return .{
                        .content_len = offset,
                        .terminator_len = raw.len,
                    };
                }
                offset += raw.len;
            }
        }

        fn scanHeaderBlockMax(self: *Self, max_bytes: usize, options: ReadHeaderBlockOptions) ReadHeaderBlockMaxError!struct {
            content_len: usize,
            terminator_len: usize,
        } {
            var offset: usize = 0;
            const max_total = max_bytes +| 2;
            while (true) {
                const raw = try self.peekRawLineAtMax(offset, max_total);
                const line = try self.decodeBorrowedLine(raw, .{
                    .line_ending = options.line_ending,
                });
                if (line.len == 0) {
                    return .{
                        .content_len = offset,
                        .terminator_len = raw.len,
                    };
                }
                if (offset > max_bytes or raw.len > max_bytes - offset) return error.BufferTooSmall;
                offset += raw.len;
            }
        }

        fn scanContinuedLineLen(self: *Self, options: ReadContinuedLineOptions) ReadContinuedLineError!usize {
            var offset: usize = 0;
            const first_raw = try self.peekRawLineAt(offset);
            _ = try self.decodeBorrowedLine(first_raw, options.line);
            offset += first_raw.len;

            while (true) {
                const window = self.peekUnreadAtLeast(offset + 1) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (window[offset] != ' ' and window[offset] != '\t') break;

                const raw = try self.peekRawLineAt(offset);
                _ = try self.decodeBorrowedLine(raw, options.line);
                offset += raw.len;
            }

            return offset;
        }

        fn scanResponseBlock(self: *Self, options: ReadResponseOptions) ReadResponseError!struct {
            code: u16,
            multiline: bool,
            total_len: usize,
        } {
            var offset: usize = 0;
            var line_count: usize = 0;

            const first_raw = try self.peekRawLineAt(offset);
            const first_line = try self.decodeBorrowedLine(first_raw, options.line);
            const first = parseCodePrefix(first_line, false) catch |err| switch (err) {
                error.InvalidResponse, error.InvalidCodeLine, error.MultiLineResponse => return error.InvalidResponse,
            };
            if (options.expect_code) |expected| {
                if (first.code != expected) return error.UnexpectedCode;
            }
            line_count += 1;
            if (line_count > options.max_lines) return error.TooManyLines;

            offset += first_raw.len;
            if (first.separator != '-') {
                return .{
                    .code = first.code,
                    .multiline = false,
                    .total_len = offset,
                };
            }

            while (true) {
                const raw = try self.peekRawLineAt(offset);
                const line = try self.decodeBorrowedLine(raw, options.line);
                offset += raw.len;

                line_count += 1;
                if (line_count > options.max_lines) return error.TooManyLines;
                if (isFinalResponseLine(line, first.code)) {
                    return .{
                        .code = first.code,
                        .multiline = true,
                        .total_len = offset,
                    };
                }
            }
        }

        fn peekRawLineAt(self: *Self, start: usize) (Io.Reader.Error || error{StreamTooLong})![]const u8 {
            var needed = start + 1;
            while (true) {
                const window = try self.peekUnreadAtLeast(needed);
                var idx = start;
                while (idx < window.len) : (idx += 1) {
                    if (window[idx] == '\n') return window[start .. idx + 1];
                }
                needed = window.len + 1;
            }
        }

        fn peekRawLineAtMax(self: *Self, start: usize, max_total: usize) (Io.Reader.Error || error{ StreamTooLong, BufferTooSmall })![]const u8 {
            var needed = start +| 1;
            while (true) {
                if (needed > max_total) return error.BufferTooSmall;
                const window = try self.peekUnreadAtLeast(needed);
                var idx = start;
                while (idx < window.len) : (idx += 1) {
                    if (window[idx] == '\n') return window[start .. idx + 1];
                }
                if (window.len >= max_total) return error.BufferTooSmall;
                needed = window.len + 1;
            }
        }

        fn peekUnreadAtLeast(self: *Self, needed: usize) (Io.Reader.Error || error{StreamTooLong})![]const u8 {
            return self.ioReader().peek(needed) catch |err| switch (err) {
                error.ReadFailed => {
                    if (self.underlyingErr()) |underlying_err| {
                        if (underlying_err == error.BufferTooSmall) return error.StreamTooLong;
                    }
                    return error.ReadFailed;
                },
                else => return err,
            };
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

fn isFinalResponseLine(line: []const u8, code: u16) bool {
    return line.len >= 4 and
        sameCode(line, code) and
        line[3] == ' ';
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

        fn takeLineTrimsCrlf() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const line = try reader.takeLine(.{});
            try testing.expectEqualStrings("PING a", line);
        }

        fn takeLineTrimsLf() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const line = try reader.takeLine(.{});
            try testing.expectEqualStrings("PING a", line);
        }

        fn takeLineTrimAsciiSpace() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("  PING a \t\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const line = try reader.takeLine(.{ .trim_ascii_space = true });
            try testing.expectEqualStrings("PING a", line);
        }

        fn takeLineRejectsLfWhenCrlfOnly() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("PING a\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.init(&buffered, .{ .default_line_ending = .crlf_only });
            defer reader.deinit();

            try expectError(error.InvalidLineEnding, reader.takeLine(.{}));
        }

        fn takeLineGrowsAcrossShortThenLongLine(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const Io = embed.Io;
            const long_body = [_]u8{'A'} ** 600;
            const input = "AT\r\n" ++ long_body ++ "\r\nOK\r\n";

            var src = Io.Reader.fixed(input);
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = try BufferedReader.initAlloc(&src, allocator, 4);
            defer buffered.deinit();
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const first = try reader.takeLine(.{});
            try lib.testing.expectEqualStrings("AT", first);

            const second = try reader.takeLine(.{});
            try testing.expectEqual(@as(usize, long_body.len), second.len);
            try testing.expect(second[0] == 'A');
            try testing.expect(second[second.len - 1] == 'A');

            const final = try reader.takeLine(.{});
            try lib.testing.expectEqualStrings("OK", final);
        }

        fn takeContinuedLineReturnsRawFoldedBlock() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("hello\r\n world\r\n\tzig \t\r\nnext\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const logical = try reader.takeContinuedLine(.{});
            try testing.expectEqualStrings("hello\r\n world\r\n\tzig \t\r\n", logical);

            const next = try reader.takeLine(.{});
            try testing.expectEqualStrings("next", next);
        }

        fn takeHeaderBlockCollectsCrlfLines() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\r\nUser-Agent: zig\r\n\r\nNEXT\r\n");
            var backing: [96]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const head = try reader.takeHeaderBlock(.{});
            try testing.expectEqualStrings("Host: example.com\r\nUser-Agent: zig\r\n", head);

            const next = try reader.takeLine(.{});
            try testing.expectEqualStrings("NEXT", next);
        }

        fn takeHeaderBlockAllowsEmptySection() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("\r\nNEXT\r\n");
            var backing: [32]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const head = try reader.takeHeaderBlock(.{});
            try testing.expectEqual(@as(usize, 0), head.len);
        }

        fn takeHeaderBlockRejectsLfWhenCrlfOnly() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\n\n");
            var backing: [48]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.InvalidLineEnding, reader.takeHeaderBlock(.{}));
        }

        fn takeHeaderBlockMaxRejectsOversizedManagedSection(allocator: lib.mem.Allocator) !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("Host: example.com\r\n\r\n");
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = try BufferedReader.initAlloc(&src, allocator, 4);
            defer buffered.deinit();
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.BufferTooSmall, reader.takeHeaderBlockMax(8, .{}));
        }

        fn takeLineGroupStopsOnTerminalLine() !void {
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
            defer reader.deinit();

            var ctx = Ctx{};
            const result = try reader.takeLineGroup(.{
                .terminal_ctx = null,
                .is_terminal = Ctx.isTerminal,
                .on_non_terminal_line_ctx = @ptrCast(&ctx),
                .on_non_terminal_line = Ctx.onInfo,
            });

            try testing.expectEqualStrings("OK", result.final_line);
            try testing.expectEqual(@as(usize, 2), result.non_terminal_lines);
            try testing.expectEqual(@as(usize, 2), ctx.count);
        }

        fn takeLineGroupRespectsNonTerminalLimit() !void {
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
            defer reader.deinit();

            try expectError(error.TooManyNonTerminalLines, reader.takeLineGroup(.{
                .max_non_terminal_lines = 1,
                .is_terminal = Cb.isTerminal,
            }));
        }

        fn takeCodeLineParsesSingleLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("220 smtp.example\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const result = try reader.takeCodeLine(.{ .expect_code = 220 });
            try testing.expectEqual(@as(u16, 220), result.code);
            try testing.expectEqualStrings("smtp.example", result.message);
        }

        fn takeCodeLineRejectsUnexpectedCode() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("421 unavailable\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.UnexpectedCode, reader.takeCodeLine(.{ .expect_code = 220 }));
        }

        fn takeCodeLineRejectsMultilineForm() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("220-smtp.example\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.MultiLineResponse, reader.takeCodeLine(.{}));
        }

        fn takeResponseParsesSingleLine() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("250 ok\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const result = try reader.takeResponse(.{ .expect_code = 250 });
            try testing.expectEqual(@as(u16, 250), result.code);
            try testing.expectEqualStrings("250 ok\r\n", result.raw);
            try testing.expect(!result.multiline);
        }

        fn takeResponseParsesMultilineBlock() !void {
            const testing = lib.testing;
            const Io = embed.Io;

            var src = Io.Reader.fixed("250-first line\r\nsecond line\r\n250 third line\r\n");
            var backing: [128]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            const result = try reader.takeResponse(.{ .expect_code = 250 });
            try testing.expectEqual(@as(u16, 250), result.code);
            try testing.expectEqualStrings("250-first line\r\nsecond line\r\n250 third line\r\n", result.raw);
            try testing.expect(result.multiline);
        }

        fn takeResponseRejectsUnexpectedCode() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("550 denied\r\n");
            var backing: [64]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.UnexpectedCode, reader.takeResponse(.{ .expect_code = 250 }));
        }

        fn takeResponseRespectsMaxLines() !void {
            const Io = embed.Io;

            var src = Io.Reader.fixed("250-first\r\nsecond\r\n250 third\r\n");
            var backing: [128]u8 = undefined;
            const BufferedReader = io.BufferedReader(@TypeOf(src));
            const TpReader = Reader(BufferedReader);
            var buffered = BufferedReader.init(&src, &backing);
            var reader = TpReader.fromBuffered(&buffered);
            defer reader.deinit();

            try expectError(error.TooManyLines, reader.takeResponse(.{
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
            defer reader.deinit();

            var dot = reader.dotReader();
            var dot_out: [64]u8 = undefined;
            const body = try readAllDot(&dot, &dot_out);
            try testing.expectEqualStrings("alpha\n.beta\n", body);

            const next = try reader.takeLine(.{});
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
            TestCase.takeLineGrowsAcrossShortThenLongLine(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            inline for (.{
                TestCase.takeLineTrimsCrlf,
                TestCase.takeLineTrimsLf,
                TestCase.takeLineTrimAsciiSpace,
                TestCase.takeLineRejectsLfWhenCrlfOnly,
                TestCase.takeContinuedLineReturnsRawFoldedBlock,
                TestCase.takeHeaderBlockCollectsCrlfLines,
                TestCase.takeHeaderBlockAllowsEmptySection,
                TestCase.takeHeaderBlockRejectsLfWhenCrlfOnly,
                TestCase.takeLineGroupStopsOnTerminalLine,
                TestCase.takeLineGroupRespectsNonTerminalLimit,
                TestCase.takeCodeLineParsesSingleLine,
                TestCase.takeCodeLineRejectsUnexpectedCode,
                TestCase.takeCodeLineRejectsMultilineForm,
                TestCase.takeResponseParsesSingleLine,
                TestCase.takeResponseParsesMultilineBlock,
                TestCase.takeResponseRejectsUnexpectedCode,
                TestCase.takeResponseRespectsMaxLines,
                TestCase.dotReaderUnstuffsAndLeavesFollowingLine,
            }) |case_fn| {
                case_fn() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
            TestCase.takeHeaderBlockMaxRejectsOversizedManagedSection(allocator) catch |err| {
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
