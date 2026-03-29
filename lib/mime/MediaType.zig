//! MediaType — shared data structures for MIME media types.
//!
//! Parsing is zero-allocation: the returned slices point into the input text,
//! and the caller provides storage for parsed parameters.

const embed = @import("embed");

const ascii = embed.ascii;
const mem = embed.mem;

const MediaType = @This();

pub const Parameter = struct {
    name: []const u8,
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

    while (rest.len > 0) {
        const segment_end = try nextParameterSegmentEnd(rest);
        const raw_segment = trimAsciiSpace(rest[0..segment_end]);
        rest = if (segment_end < rest.len) rest[segment_end + 1 ..] else "";

        if (raw_segment.len == 0) continue;
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
        0...31, 127 => false,
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

    try validateQuotedPayload(value);

    try writer.writeByte('"');
    for (value) |c| {
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

fn validateQuotedPayload(value: []const u8) ParseError!void {
    var i: usize = 0;
    while (i < value.len) {
        switch (value[i]) {
            '\\' => {
                if (i + 1 >= value.len) return error.InvalidQuotedPair;
                i += 2;
                continue;
            },
            '"' => return error.InvalidQuotedPair,
            else => i += 1,
        }
    }
}

test "mime/unit_tests/MediaType/init_stores_value_and_params" {
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

test "mime/unit_tests/MediaType/parse_parses_value_and_params_without_allocation" {
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

test "mime/unit_tests/MediaType/parse_accepts_quoted_parameter_values" {
    const std = @import("std");
    var params_buf: [1]Parameter = undefined;
    const mt = try MediaType.parse("text/plain; charset=\"utf-8\"", &params_buf);

    try std.testing.expectEqualStrings("text/plain", mt.value);
    try std.testing.expectEqual(@as(usize, 1), mt.params.len);
    try std.testing.expectEqualStrings("charset", mt.params[0].name);
    try std.testing.expectEqualStrings("utf-8", mt.params[0].value);
}

test "mime/unit_tests/MediaType/parse_accepts_semicolons_inside_quoted_parameter_values" {
    const std = @import("std");
    var params_buf: [1]Parameter = undefined;
    const mt = try MediaType.parse("text/plain; title=\"hello;world\"", &params_buf);

    try std.testing.expectEqualStrings("text/plain", mt.value);
    try std.testing.expectEqual(@as(usize, 1), mt.params.len);
    try std.testing.expectEqualStrings("title", mt.params[0].name);
    try std.testing.expectEqualStrings("hello;world", mt.params[0].value);
}

test "mime/unit_tests/MediaType/parse_accepts_quoted_pair_escapes" {
    const std = @import("std");
    var params_buf: [1]Parameter = undefined;
    const mt = try MediaType.parse("text/plain; title=\"hello\\\"world\\\\path\"", &params_buf);

    try std.testing.expectEqualStrings("text/plain", mt.value);
    try std.testing.expectEqual(@as(usize, 1), mt.params.len);
    try std.testing.expectEqualStrings("title", mt.params[0].name);
    try std.testing.expectEqualStrings("hello\\\"world\\\\path", mt.params[0].value);
}

test "mime/unit_tests/MediaType/format_writes_media_type_text" {
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

test "mime/unit_tests/MediaType/format_rejects_values_requiring_escape_sequences" {
    const std = @import("std");
    const params = [_]Parameter{
        .{ .name = "title", .value = "hello\"world" },
    };
    const mt = MediaType.init("text/plain", &params);

    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(error.InvalidQuotedPair, mt.format(stream.writer()));
}

test "mime/unit_tests/MediaType/format_preserves_quoted_pair_escapes" {
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
