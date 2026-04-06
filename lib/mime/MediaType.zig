//! MediaType — shared data structures for MIME media types.
//!
//! Parsing is zero-allocation: the returned slices point into the input text,
//! and the caller provides storage for parsed parameters.

const embed = @import("embed");
const testing_api = @import("testing");

const ascii = embed.ascii;
const mem = embed.mem;

const MediaType = @This();

pub const Parameter = struct {
    name: []const u8,
    // Parsed values are raw slices into the input. Quoted strings keep any
    // quoted-pair escapes rather than decoding them into a separate buffer.
    value: []const u8,
};

pub const ParseError = error{
    InvalidMediaType,
    InvalidParameter,
    TooManyParameters,
    UnterminatedQuotedValue,
    InvalidQuotedPair,
};

value: []const u8,
params: []const Parameter = &.{},

// init is unchecked. Use parse(...) when the media type text comes from an
// untrusted source, and rely on format(...) to validate before serialization.
pub fn init(value: []const u8, params: []const Parameter) MediaType {
    return .{
        .value = value,
        .params = params,
    };
}

pub fn parse(input: []const u8, params_buf: []Parameter) ParseError!MediaType {
    const value_end = mem.indexOfScalar(u8, input, ';') orelse input.len;
    const value = trimAsciiSpace(input[0..value_end]);
    if (!isValidMediaTypeValue(value)) return error.InvalidMediaType;

    var params_len: usize = 0;
    var rest = if (value_end < input.len) input[value_end + 1 ..] else "";
    if (value_end < input.len and rest.len == 0) return error.InvalidParameter;

    while (rest.len > 0) {
        const segment_end = try nextParameterSegmentEnd(rest);
        const raw_segment = trimAsciiSpace(rest[0..segment_end]);
        rest = if (segment_end < rest.len) rest[segment_end + 1 ..] else "";

        if (raw_segment.len == 0) return error.InvalidParameter;
        if (params_len >= params_buf.len) return error.TooManyParameters;

        const eq_idx = mem.indexOfScalar(u8, raw_segment, '=') orelse return error.InvalidParameter;
        const name = trimAsciiSpace(raw_segment[0..eq_idx]);
        const raw_value = trimAsciiSpace(raw_segment[eq_idx + 1 ..]);
        if (!isToken(name) or raw_value.len == 0) return error.InvalidParameter;

        params_buf[params_len] = .{
            .name = name,
            .value = try parseParameterValue(raw_value),
        };
        params_len += 1;
    }

    return .{
        .value = value,
        .params = params_buf[0..params_len],
    };
}

fn nextParameterSegmentEnd(text: []const u8) ParseError!usize {
    var in_quotes = false;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            ';' => if (!in_quotes) return i,
            '"' => in_quotes = !in_quotes,
            '\\' => {
                // Keep scanning past the escaped byte so a quoted value like
                // "a\;b" or "a\"b" does not desynchronize segment splitting.
                if (in_quotes and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
            },
            else => {},
        }
        i += 1;
    }
    if (in_quotes) return error.UnterminatedQuotedValue;
    return text.len;
}

pub fn format(self: MediaType, writer: anytype) !void {
    if (!isValidMediaTypeValue(self.value)) return error.InvalidMediaType;
    for (self.params) |param| {
        if (!isToken(param.name)) return error.InvalidParameter;
        try validateParameterValueForFormat(param.value);
    }

    try writer.writeAll(self.value);
    for (self.params) |param| {
        try writer.writeAll("; ");
        try writer.writeAll(param.name);
        try writer.writeByte('=');
        try formatParameterValue(param.value, writer);
    }
}

fn trimAsciiSpace(text: []const u8) []const u8 {
    return mem.trim(u8, text, &ascii.whitespace);
}

fn isValidMediaTypeValue(value: []const u8) bool {
    const slash_idx = mem.indexOfScalar(u8, value, '/') orelse return false;
    if (slash_idx == 0 or slash_idx + 1 >= value.len) return false;
    return isToken(value[0..slash_idx]) and isToken(value[slash_idx + 1 ..]);
}

fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        0...31, 127...255 => false,
        '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', ' ' => false,
        else => true,
    };
}

fn parseParameterValue(raw_value: []const u8) ParseError![]const u8 {
    if (raw_value.len == 0) return error.InvalidParameter;
    if (raw_value[0] != '"') {
        if (!isToken(raw_value)) return error.InvalidParameter;
        return raw_value;
    }
    if (raw_value.len < 2 or raw_value[raw_value.len - 1] != '"') return error.UnterminatedQuotedValue;

    const inner = raw_value[1 .. raw_value.len - 1];
    try validateQuotedPayload(inner);
    return inner;
}

fn formatParameterValue(value: []const u8, writer: anytype) !void {
    if (isToken(value)) {
        try writer.writeAll(value);
        return;
    }

    try validateParameterValueForFormat(value);

    try writer.writeByte('"');
    for (value) |c| {
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

fn validateParameterValueForFormat(value: []const u8) ParseError!void {
    if (isToken(value)) return;
    try validateQuotedPayload(value);
}

fn validateQuotedPayload(value: []const u8) ParseError!void {
    var i: usize = 0;
    while (i < value.len) {
        switch (value[i]) {
            '\\' => {
                if (i + 1 >= value.len or !isValidQuotedPairChar(value[i + 1])) {
                    return error.InvalidQuotedPair;
                }
                i += 2;
                continue;
            },
            '"' => return error.InvalidQuotedPair,
            0...31, 127...255 => return error.InvalidQuotedPair,
            else => i += 1,
        }
    }
}

fn isValidQuotedPairChar(c: u8) bool {
    return switch (c) {
        0...31, 127...255 => false,
        else => true,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testInitStoresValueAndParams() !void {
            const std = @import("std");
            const params = [_]Parameter{
                .{ .name = "charset", .value = "utf-8" },
            };
            const mt = MediaType.init("text/html", &params);

            try std.testing.expectEqualStrings("text/html", mt.value);
            try std.testing.expectEqual(@as(usize, 1), mt.params.len);
            try std.testing.expectEqualStrings("charset", mt.params[0].name);
            try std.testing.expectEqualStrings("utf-8", mt.params[0].value);
        }
        fn testParseParsesValueAndParamsWithoutAllocation() !void {
            const std = @import("std");
            var params_buf: [2]Parameter = undefined;
            const mt = try MediaType.parse("text/html; charset=utf-8; boundary=abc123", &params_buf);

            try std.testing.expectEqualStrings("text/html", mt.value);
            try std.testing.expectEqual(@as(usize, 2), mt.params.len);
            try std.testing.expectEqualStrings("charset", mt.params[0].name);
            try std.testing.expectEqualStrings("utf-8", mt.params[0].value);
            try std.testing.expectEqualStrings("boundary", mt.params[1].name);
            try std.testing.expectEqualStrings("abc123", mt.params[1].value);
        }
        fn testParseAcceptsQuotedParameterValues() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;
            const mt = try MediaType.parse("text/plain; charset=\"utf-8\"", &params_buf);

            try std.testing.expectEqualStrings("text/plain", mt.value);
            try std.testing.expectEqual(@as(usize, 1), mt.params.len);
            try std.testing.expectEqualStrings("charset", mt.params[0].name);
            try std.testing.expectEqualStrings("utf-8", mt.params[0].value);
        }
        fn testParseAcceptsSemicolonsInsideQuotedParameterValues() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;
            const mt = try MediaType.parse("text/plain; title=\"hello;world\"", &params_buf);

            try std.testing.expectEqualStrings("text/plain", mt.value);
            try std.testing.expectEqual(@as(usize, 1), mt.params.len);
            try std.testing.expectEqualStrings("title", mt.params[0].name);
            try std.testing.expectEqualStrings("hello;world", mt.params[0].value);
        }
        fn testParseAcceptsQuotedPairEscapes() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;
            const mt = try MediaType.parse("text/plain; title=\"hello\\\"world\\\\path\"", &params_buf);

            try std.testing.expectEqualStrings("text/plain", mt.value);
            try std.testing.expectEqual(@as(usize, 1), mt.params.len);
            try std.testing.expectEqualStrings("title", mt.params[0].name);
            try std.testing.expectEqualStrings("hello\\\"world\\\\path", mt.params[0].value);
        }
        fn testParseRejectsUnterminatedQuotedValues() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.UnterminatedQuotedValue, MediaType.parse("text/plain; title=\"unterminated", &params_buf));
            try std.testing.expectError(error.UnterminatedQuotedValue, MediaType.parse("text/plain; title=\"unterminated; charset=utf-8", &params_buf));
        }
        fn testParseRejectsEmptyParameterSegments() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain;", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain;;charset=utf-8", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain; ; charset=utf-8", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain;   ", &params_buf));
        }
        fn testParseRejectsNonAsciiTokens() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("te\xE9xt/plain", &params_buf));
            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("text/pl\xFFain", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain; na\xE9me=value", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain; name=\xE9", &params_buf));
        }
        fn testParseRejectsControlBytesInQuotedValues() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.InvalidQuotedPair, MediaType.parse("text/plain; title=\"hello\rworld\"", &params_buf));
            try std.testing.expectError(error.InvalidQuotedPair, MediaType.parse("text/plain; title=\"hello\nworld\"", &params_buf));
        }
        fn testParseRejectsInvalidMediaTypeShapes() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("text", &params_buf));
            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("/plain", &params_buf));
            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("text/", &params_buf));
            try std.testing.expectError(error.InvalidMediaType, MediaType.parse("text /plain", &params_buf));
        }
        fn testParseRejectsInvalidUnquotedParameterValues() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain; title=hello world", &params_buf));
            try std.testing.expectError(error.InvalidParameter, MediaType.parse("text/plain; title=hello,world", &params_buf));
        }
        fn testParseRejectsTooManyParameters() !void {
            const std = @import("std");
            var params_buf: [1]Parameter = undefined;

            try std.testing.expectError(
                error.TooManyParameters,
                MediaType.parse("text/plain; charset=utf-8; boundary=abc123", &params_buf),
            );
        }
        fn testFormatWritesMediaTypeText() !void {
            const std = @import("std");
            const params = [_]Parameter{
                .{ .name = "charset", .value = "utf-8" },
                .{ .name = "filename", .value = "hello world.txt" },
            };
            const mt = MediaType.init("text/plain", &params);

            var buf: [128]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try mt.format(stream.writer());

            try std.testing.expectEqualStrings(
                "text/plain; charset=utf-8; filename=\"hello world.txt\"",
                stream.getWritten(),
            );
        }
        fn testFormatRejectsValuesRequiringEscapeSequences() !void {
            const std = @import("std");
            const params = [_]Parameter{
                .{ .name = "title", .value = "hello\"world" },
            };
            const mt = MediaType.init("text/plain", &params);

            var buf: [128]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try std.testing.expectError(error.InvalidQuotedPair, mt.format(stream.writer()));
        }
        fn testFormatPreservesQuotedPairEscapes() !void {
            const std = @import("std");
            const params = [_]Parameter{
                .{ .name = "title", .value = "hello\\\"world\\\\path" },
            };
            const mt = MediaType.init("text/plain", &params);

            var buf: [128]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try mt.format(stream.writer());

            try std.testing.expectEqualStrings(
                "text/plain; title=\"hello\\\"world\\\\path\"",
                stream.getWritten(),
            );
        }
        fn testParseAndFormatRoundtripQuotedValuesWithoutDecoding() !void {
            const std = @import("std");

            var parsed_params: [1]Parameter = undefined;
            const parsed = try MediaType.parse("text/plain; title=\"hello\\\"world\\\\path\"", &parsed_params);

            var buf: [128]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try parsed.format(stream.writer());
            try std.testing.expectEqualStrings(
                "text/plain; title=\"hello\\\"world\\\\path\"",
                stream.getWritten(),
            );

            var reparsed_params: [1]Parameter = undefined;
            const reparsed = try MediaType.parse(stream.getWritten(), &reparsed_params);
            try std.testing.expectEqualStrings(parsed.value, reparsed.value);
            try std.testing.expectEqual(@as(usize, 1), reparsed.params.len);
            try std.testing.expectEqualStrings(parsed.params[0].name, reparsed.params[0].name);
            try std.testing.expectEqualStrings(parsed.params[0].value, reparsed.params[0].value);
        }
        fn testFormatRejectsInvalidMediaTypeAndParameterNames() !void {
            const std = @import("std");
            const bad_type = MediaType.init("text/plain\r\nX-Test: yes", &.{});
            const bad_name_params = [_]Parameter{
                .{ .name = "charset", .value = "utf-8" },
                .{ .name = "file\xE9name", .value = "report.txt" },
            };
            const bad_name = MediaType.init("text/plain", &bad_name_params);

            var type_buf: [128]u8 = undefined;
            var type_stream = std.io.fixedBufferStream(&type_buf);
            try std.testing.expectError(error.InvalidMediaType, bad_type.format(type_stream.writer()));
            try std.testing.expectEqual(@as(usize, 0), type_stream.getWritten().len);

            var name_buf: [128]u8 = undefined;
            var name_stream = std.io.fixedBufferStream(&name_buf);
            try std.testing.expectError(error.InvalidParameter, bad_name.format(name_stream.writer()));
            try std.testing.expectEqual(@as(usize, 0), name_stream.getWritten().len);
        }
        fn testFormatRejectsControlBytesInQuotedValues() !void {
            const std = @import("std");
            const params = [_]Parameter{
                .{ .name = "title", .value = "hello\rworld" },
            };
            const mt = MediaType.init("text/plain", &params);

            var buf: [128]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try std.testing.expectError(error.InvalidQuotedPair, mt.format(stream.writer()));
            try std.testing.expectEqual(@as(usize, 0), stream.getWritten().len);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testInitStoresValueAndParams() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseParsesValueAndParamsWithoutAllocation() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseAcceptsQuotedParameterValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseAcceptsSemicolonsInsideQuotedParameterValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseAcceptsQuotedPairEscapes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsUnterminatedQuotedValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsEmptyParameterSegments() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsNonAsciiTokens() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsControlBytesInQuotedValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsInvalidMediaTypeShapes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsInvalidUnquotedParameterValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseRejectsTooManyParameters() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFormatWritesMediaTypeText() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFormatRejectsValuesRequiringEscapeSequences() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFormatPreservesQuotedPairEscapes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testParseAndFormatRoundtripQuotedValuesWithoutDecoding() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFormatRejectsInvalidMediaTypeAndParameterNames() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testFormatRejectsControlBytesInQuotedValues() catch |err| {
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
