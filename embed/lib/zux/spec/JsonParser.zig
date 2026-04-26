const glib = @import("glib");

const JsonParser = @This();

source: []const u8,
index: usize = 0,

pub fn init(comptime source: []const u8) JsonParser {
    return .{
        .source = source,
    };
}

pub fn finish(self: *JsonParser) void {
    self.skipWhitespace();
    if (self.index != self.source.len) {
        @compileError("zux.spec.JsonParser found trailing JSON content");
    }
}

pub fn skipWhitespace(self: *JsonParser) void {
    while (self.index < self.source.len) : (self.index += 1) {
        switch (self.source[self.index]) {
            ' ', '\n', '\r', '\t' => {},
            else => return,
        }
    }
}

pub fn expectByte(self: *JsonParser, comptime byte: u8) void {
    self.skipWhitespace();
    if (self.index >= self.source.len or self.source[self.index] != byte) {
        @compileError("zux.spec.JsonParser encountered invalid JSON syntax");
    }
    self.index += 1;
}

pub fn consumeByte(self: *JsonParser, comptime byte: u8) bool {
    self.skipWhitespace();
    if (self.index < self.source.len and self.source[self.index] == byte) {
        self.index += 1;
        return true;
    }
    return false;
}

pub fn peekByte(self: *JsonParser) u8 {
    self.skipWhitespace();
    if (self.index >= self.source.len) {
        @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
    }
    return self.source[self.index];
}

pub fn parseString(self: *JsonParser) []const u8 {
    self.skipWhitespace();
    if (self.index >= self.source.len or self.source[self.index] != '"') {
        @compileError("zux.spec.JsonParser expected a JSON string");
    }

    const string_start = self.index;
    const info = scanDecodedStringInfo(self.source, string_start);
    const raw_text = self.source[string_start + 1 .. info.next_index - 1];
    self.index = info.next_index;

    if (!containsByte(raw_text, '\\')) {
        return raw_text;
    }

    const decoded = comptime blk: {
        var bytes: [info.decoded_len]u8 = undefined;
        const next_index = decodeStringInto(self.source, string_start, &bytes);
        if (next_index != info.next_index) {
            @compileError("zux.spec.JsonParser decoded string length mismatch");
        }
        break :blk bytes;
    };
    return decoded[0..];
}

pub fn parseBool(self: *JsonParser) bool {
    self.skipWhitespace();
    if (startsWithAt(self.source, self.index, "true")) {
        self.index += 4;
        return true;
    }
    if (startsWithAt(self.source, self.index, "false")) {
        self.index += 5;
        return false;
    }
    @compileError("zux.spec.JsonParser expected a JSON bool");
}

pub fn expectNull(self: *JsonParser) void {
    self.skipWhitespace();
    if (!startsWithAt(self.source, self.index, "null")) {
        @compileError("zux.spec.JsonParser expected JSON null");
    }
    self.index += 4;
}

pub fn parseI128(self: *JsonParser) i128 {
    self.skipWhitespace();
    const start = self.index;

    if (self.index < self.source.len and self.source[self.index] == '-') {
        self.index += 1;
    }
    if (self.index >= self.source.len or !isDigit(self.source[self.index])) {
        @compileError("zux.spec.JsonParser expected a JSON integer");
    }
    while (self.index < self.source.len and isDigit(self.source[self.index])) : (self.index += 1) {}

    if (self.index < self.source.len) {
        switch (self.source[self.index]) {
            '.', 'e', 'E' => @compileError("zux.spec.JsonParser expected a JSON integer"),
            else => {},
        }
    }

    return parseI128Slice(self.source[start..self.index]);
}

pub fn parseUsize(self: *JsonParser) usize {
    const value = self.parseI128();
    if (value < 0) {
        @compileError("zux.spec.JsonParser integer must not be negative");
    }
    return @intCast(value);
}

pub fn parseU32(self: *JsonParser) u32 {
    const value = self.parseI128();
    if (value < 0) {
        @compileError("zux.spec.JsonParser integer must not be negative");
    }
    return @intCast(value);
}

pub fn parseValueSlice(self: *JsonParser) []const u8 {
    self.skipWhitespace();
    const start = self.index;
    self.skipValue();
    return self.source[start..self.index];
}

pub fn skipValue(self: *JsonParser) void {
    self.index = scanValue(self.source, self.index);
}

pub fn countArrayItems(self: JsonParser) usize {
    var copy = self;
    copy.expectByte('[');
    if (copy.consumeByte(']')) return 0;

    var count: usize = 0;
    while (true) {
        _ = copy.parseValueSlice();
        count += 1;
        if (copy.consumeByte(',')) continue;
        copy.expectByte(']');
        return count;
    }
}

pub fn countObjectFields(self: JsonParser) usize {
    var copy = self;
    copy.expectByte('{');
    if (copy.consumeByte('}')) return 0;

    var count: usize = 0;
    while (true) {
        _ = copy.parseString();
        copy.expectByte(':');
        _ = copy.parseValueSlice();
        count += 1;
        if (copy.consumeByte(',')) continue;
        copy.expectByte('}');
        return count;
    }
}

fn parseI128Slice(comptime text: []const u8) i128 {
    if (text.len == 0) {
        @compileError("zux.spec.JsonParser expected a JSON integer");
    }

    var index: usize = 0;
    var negative = false;
    if (text[index] == '-') {
        negative = true;
        index += 1;
    }
    if (index >= text.len) {
        @compileError("zux.spec.JsonParser expected digits after '-'");
    }

    var value: i128 = 0;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        if (!isDigit(ch)) {
            @compileError("zux.spec.JsonParser expected a JSON integer");
        }
        value = value * 10 + @as(i128, ch - '0');
    }
    return if (negative) -value else value;
}

const DecodedStringInfo = struct {
    next_index: usize,
    decoded_len: usize,
};

const UnicodeEscape = struct {
    code_point: u21,
    next_index: usize,
};

fn scanDecodedStringInfo(
    comptime source: []const u8,
    comptime start_index: usize,
) DecodedStringInfo {
    if (start_index >= source.len or source[start_index] != '"') {
        @compileError("zux.spec.JsonParser expected a JSON string");
    }

    var index = start_index + 1;
    var decoded_len: usize = 0;
    while (index < source.len) {
        switch (source[index]) {
            '"' => return .{
                .next_index = index + 1,
                .decoded_len = decoded_len,
            },
            '\\' => {
                index += 1;
                if (index >= source.len) {
                    @compileError("zux.spec.JsonParser found an unterminated JSON escape sequence");
                }
                switch (source[index]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        decoded_len += 1;
                        index += 1;
                    },
                    'u' => {
                        const escape = decodeUnicodeEscapeSequence(source, index);
                        decoded_len += utf8Len(escape.code_point);
                        index = escape.next_index;
                    },
                    else => @compileError("zux.spec.JsonParser encountered an unsupported JSON escape"),
                }
            },
            else => {
                if (source[index] < 0x20) {
                    @compileError("zux.spec.JsonParser encountered an unescaped control character inside a JSON string");
                }
                decoded_len += 1;
                index += 1;
            },
        }
    }

    @compileError("zux.spec.JsonParser found an unterminated JSON string");
}

fn decodeStringInto(
    comptime source: []const u8,
    comptime start_index: usize,
    out: []u8,
) usize {
    var index = start_index + 1;
    var out_index: usize = 0;

    while (index < source.len) {
        switch (source[index]) {
            '"' => return index + 1,
            '\\' => {
                index += 1;
                if (index >= source.len) {
                    @compileError("zux.spec.JsonParser found an unterminated JSON escape sequence");
                }
                switch (source[index]) {
                    '"' => out[out_index] = '"',
                    '\\' => out[out_index] = '\\',
                    '/' => out[out_index] = '/',
                    'b' => out[out_index] = '\x08',
                    'f' => out[out_index] = '\x0c',
                    'n' => out[out_index] = '\n',
                    'r' => out[out_index] = '\r',
                    't' => out[out_index] = '\t',
                    'u' => {
                        const escape = decodeUnicodeEscapeSequence(source, index);
                        out_index += writeUtf8(out[out_index..], escape.code_point);
                        index = escape.next_index;
                        continue;
                    },
                    else => @compileError("zux.spec.JsonParser encountered an unsupported JSON escape"),
                }
                out_index += 1;
                index += 1;
            },
            else => {
                if (source[index] < 0x20) {
                    @compileError("zux.spec.JsonParser encountered an unescaped control character inside a JSON string");
                }
                out[out_index] = source[index];
                out_index += 1;
                index += 1;
            },
        }
    }

    @compileError("zux.spec.JsonParser found an unterminated JSON string");
}

fn parseUnicodeEscape(comptime digits: []const u8) u21 {
    if (digits.len != 4) {
        @compileError("zux.spec.JsonParser expected a 4-digit unicode escape");
    }

    var value: u21 = 0;
    inline for (digits) |digit| {
        value = value * 16 + hexDigitValue(digit);
    }
    return value;
}

fn decodeUnicodeEscapeSequence(
    comptime source: []const u8,
    comptime u_index: usize,
) UnicodeEscape {
    if (u_index + 4 >= source.len) {
        @compileError("zux.spec.JsonParser found an incomplete unicode escape");
    }

    const first = parseUnicodeEscape(source[u_index + 1 .. u_index + 5]);
    if (first >= 0xd800 and first <= 0xdbff) {
        const next_escape_index = u_index + 5;
        if (next_escape_index + 5 >= source.len or
            source[next_escape_index] != '\\' or
            source[next_escape_index + 1] != 'u')
        {
            @compileError("zux.spec.JsonParser found a unicode high surrogate without a matching low surrogate");
        }

        const second = parseUnicodeEscape(source[next_escape_index + 2 .. next_escape_index + 6]);
        if (second < 0xdc00 or second > 0xdfff) {
            @compileError("zux.spec.JsonParser found an invalid unicode surrogate pair");
        }

        return .{
            .code_point = 0x10000 + (((first - 0xd800) << 10) | (second - 0xdc00)),
            .next_index = next_escape_index + 6,
        };
    }
    if (first >= 0xdc00 and first <= 0xdfff) {
        @compileError("zux.spec.JsonParser found a unicode low surrogate without a preceding high surrogate");
    }

    return .{
        .code_point = first,
        .next_index = u_index + 5,
    };
}

fn hexDigitValue(ch: u8) u21 {
    return switch (ch) {
        '0'...'9' => @as(u21, ch - '0'),
        'a'...'f' => @as(u21, ch - 'a') + 10,
        'A'...'F' => @as(u21, ch - 'A') + 10,
        else => @compileError("zux.spec.JsonParser encountered an invalid hex digit"),
    };
}

fn utf8Len(code_point: u21) usize {
    return switch (code_point) {
        0x0000...0x007f => 1,
        0x0080...0x07ff => 2,
        0x0800...0xffff => 3,
        0x10000...0x10ffff => 4,
        else => @compileError("zux.spec.JsonParser encountered an invalid unicode code point"),
    };
}

fn writeUtf8(out: []u8, code_point: u21) usize {
    switch (utf8Len(code_point)) {
        1 => {
            out[0] = @intCast(code_point);
            return 1;
        },
        2 => {
            out[0] = 0b1100_0000 | @as(u8, @intCast(code_point >> 6));
            out[1] = 0b1000_0000 | @as(u8, @intCast(code_point & 0b0011_1111));
            return 2;
        },
        3 => {
            out[0] = 0b1110_0000 | @as(u8, @intCast(code_point >> 12));
            out[1] = 0b1000_0000 | @as(u8, @intCast((code_point >> 6) & 0b0011_1111));
            out[2] = 0b1000_0000 | @as(u8, @intCast(code_point & 0b0011_1111));
            return 3;
        },
        4 => {
            out[0] = 0b1111_0000 | @as(u8, @intCast(code_point >> 18));
            out[1] = 0b1000_0000 | @as(u8, @intCast((code_point >> 12) & 0b0011_1111));
            out[2] = 0b1000_0000 | @as(u8, @intCast((code_point >> 6) & 0b0011_1111));
            out[3] = 0b1000_0000 | @as(u8, @intCast(code_point & 0b0011_1111));
            return 4;
        },
        else => unreachable,
    }
}

fn scanValue(comptime source: []const u8, comptime start_index: usize) usize {
    const index = skipWhitespaceAt(source, start_index);
    if (index >= source.len) {
        @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
    }

    return switch (source[index]) {
        '"' => scanString(source, index),
        '{' => scanObject(source, index),
        '[' => scanArray(source, index),
        't' => scanKeyword(source, index, "true"),
        'f' => scanKeyword(source, index, "false"),
        'n' => scanKeyword(source, index, "null"),
        '-', '0'...'9' => scanNumber(source, index),
        else => @compileError("zux.spec.JsonParser encountered unsupported JSON syntax"),
    };
}

fn scanObject(comptime source: []const u8, comptime start_index: usize) usize {
    var index = start_index + 1;
    while (true) {
        index = skipWhitespaceAt(source, index);
        if (index >= source.len) {
            @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
        }
        if (source[index] == '}') return index + 1;

        index = scanString(source, index);
        index = skipWhitespaceAt(source, index);
        if (index >= source.len or source[index] != ':') {
            @compileError("zux.spec.JsonParser encountered invalid JSON object syntax");
        }
        index += 1;
        index = scanValue(source, index);
        index = skipWhitespaceAt(source, index);
        if (index >= source.len) {
            @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
        }
        if (source[index] == ',') {
            index += 1;
            continue;
        }
        if (source[index] == '}') return index + 1;

        @compileError("zux.spec.JsonParser encountered invalid JSON object syntax");
    }
}

fn scanArray(comptime source: []const u8, comptime start_index: usize) usize {
    var index = start_index + 1;
    while (true) {
        index = skipWhitespaceAt(source, index);
        if (index >= source.len) {
            @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
        }
        if (source[index] == ']') return index + 1;

        index = scanValue(source, index);
        index = skipWhitespaceAt(source, index);
        if (index >= source.len) {
            @compileError("zux.spec.JsonParser reached the end of JSON unexpectedly");
        }
        if (source[index] == ',') {
            index += 1;
            continue;
        }
        if (source[index] == ']') return index + 1;

        @compileError("zux.spec.JsonParser encountered invalid JSON array syntax");
    }
}

fn scanString(comptime source: []const u8, comptime start_index: usize) usize {
    if (start_index >= source.len or source[start_index] != '"') {
        @compileError("zux.spec.JsonParser expected a JSON string");
    }

    var index = start_index + 1;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            '"' => return index + 1,
            '\\' => {
                index += 1;
                if (index >= source.len) {
                    @compileError("zux.spec.JsonParser found an unterminated JSON escape sequence");
                }
            },
            else => {
                if (source[index] < 0x20) {
                    @compileError("zux.spec.JsonParser encountered an unescaped control character inside a JSON string");
                }
            },
        }
    }

    @compileError("zux.spec.JsonParser found an unterminated JSON string");
}

fn scanKeyword(
    comptime source: []const u8,
    comptime start_index: usize,
    comptime keyword: []const u8,
) usize {
    if (!startsWithAt(source, start_index, keyword)) {
        @compileError("zux.spec.JsonParser encountered invalid JSON syntax");
    }
    return start_index + keyword.len;
}

fn scanNumber(comptime source: []const u8, comptime start_index: usize) usize {
    var index = start_index;
    if (source[index] == '-') {
        index += 1;
        if (index >= source.len) {
            @compileError("zux.spec.JsonParser encountered invalid JSON number syntax");
        }
    }

    if (!isDigit(source[index])) {
        @compileError("zux.spec.JsonParser encountered invalid JSON number syntax");
    }
    if (source[index] == '0') {
        index += 1;
    } else {
        while (index < source.len and isDigit(source[index])) : (index += 1) {}
    }

    if (index < source.len and source[index] == '.') {
        index += 1;
        if (index >= source.len or !isDigit(source[index])) {
            @compileError("zux.spec.JsonParser encountered invalid JSON number syntax");
        }
        while (index < source.len and isDigit(source[index])) : (index += 1) {}
    }

    if (index < source.len and (source[index] == 'e' or source[index] == 'E')) {
        index += 1;
        if (index < source.len and (source[index] == '+' or source[index] == '-')) {
            index += 1;
        }
        if (index >= source.len or !isDigit(source[index])) {
            @compileError("zux.spec.JsonParser encountered invalid JSON number syntax");
        }
        while (index < source.len and isDigit(source[index])) : (index += 1) {}
    }

    return index;
}

fn skipWhitespaceAt(comptime source: []const u8, comptime start_index: usize) usize {
    var index = start_index;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            ' ', '\n', '\r', '\t' => {},
            else => return index,
        }
    }
    return index;
}

fn startsWithAt(
    comptime source: []const u8,
    comptime start_index: usize,
    comptime needle: []const u8,
) bool {
    if (start_index + needle.len > source.len) return false;
    inline for (needle, 0..) |ch, i| {
        if (source[start_index + i] != ch) return false;
    }
    return true;
}

fn containsByte(bytes: []const u8, needle: u8) bool {
    for (bytes) |byte| {
        if (byte == needle) return true;
    }
    return false;
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn parses_scalars_and_whitespace(allocator: glib.std.mem.Allocator) !void {
            _ = allocator;

            const source =
                \\  { "name": "counter", "enabled": true, "count": 42, "none": null }
            ;

            const parsed = comptime blk: {
                var parser = JsonParser.init(source);
                parser.expectByte('{');

                const name_key = parser.parseString();
                parser.expectByte(':');
                const name_value = parser.parseString();
                _ = parser.consumeByte(',');

                const enabled_key = parser.parseString();
                parser.expectByte(':');
                const enabled_value = parser.parseBool();
                _ = parser.consumeByte(',');

                const count_key = parser.parseString();
                parser.expectByte(':');
                const count_value = parser.parseI128();
                _ = parser.consumeByte(',');

                const none_key = parser.parseString();
                parser.expectByte(':');
                parser.expectNull();
                parser.expectByte('}');
                parser.finish();

                break :blk .{
                    .name_key = name_key,
                    .name_value = name_value,
                    .enabled_key = enabled_key,
                    .enabled_value = enabled_value,
                    .count_key = count_key,
                    .count_value = count_value,
                    .none_key = none_key,
                };
            };

            try grt.std.testing.expectEqualStrings("name", parsed.name_key);
            try grt.std.testing.expectEqualStrings("counter", parsed.name_value);
            try grt.std.testing.expectEqualStrings("enabled", parsed.enabled_key);
            try grt.std.testing.expectEqual(true, parsed.enabled_value);
            try grt.std.testing.expectEqualStrings("count", parsed.count_key);
            try grt.std.testing.expectEqual(@as(i128, 42), parsed.count_value);
            try grt.std.testing.expectEqualStrings("none", parsed.none_key);
        }

        fn slices_nested_values(allocator: glib.std.mem.Allocator) !void {
            _ = allocator;

            const source =
                \\{
                \\  "items": [1, {"deep": [true, false]}, 3],
                \\  "object": {"left": 1, "right": {"ok": true}}
                \\}
            ;

            const parsed = comptime blk: {
                var parser = JsonParser.init(source);
                parser.expectByte('{');

                const items_key = parser.parseString();
                parser.expectByte(':');
                const items_slice = parser.parseValueSlice();
                _ = parser.consumeByte(',');

                const object_key = parser.parseString();
                parser.expectByte(':');
                const object_slice = parser.parseValueSlice();
                parser.expectByte('}');
                parser.finish();

                var array_parser = JsonParser.init(items_slice);
                const array_count = array_parser.countArrayItems();

                var object_parser = JsonParser.init(object_slice);
                const object_count = object_parser.countObjectFields();

                break :blk .{
                    .items_key = items_key,
                    .items_slice = items_slice,
                    .items_count = array_count,
                    .object_key = object_key,
                    .object_slice = object_slice,
                    .object_count = object_count,
                };
            };

            try grt.std.testing.expectEqualStrings("items", parsed.items_key);
            try grt.std.testing.expectEqualStrings("[1, {\"deep\": [true, false]}, 3]", parsed.items_slice);
            try grt.std.testing.expectEqual(@as(usize, 3), parsed.items_count);
            try grt.std.testing.expectEqualStrings("object", parsed.object_key);
            try grt.std.testing.expectEqualStrings("{\"left\": 1, \"right\": {\"ok\": true}}", parsed.object_slice);
            try grt.std.testing.expectEqual(@as(usize, 2), parsed.object_count);
        }

        fn decodes_escaped_strings(allocator: glib.std.mem.Allocator) !void {
            _ = allocator;

            const source =
                \\[
                \\  "line 1\nline 2",
                \\  "quote: \"ok\"",
                \\  "\uD83D\uDE00"
                \\]
            ;

            const parsed = comptime blk: {
                var parser = JsonParser.init(source);
                parser.expectByte('[');
                const first = parser.parseString();
                _ = parser.consumeByte(',');
                const second = parser.parseString();
                _ = parser.consumeByte(',');
                const third = parser.parseString();
                parser.expectByte(']');
                parser.finish();
                break :blk .{
                    .first = first,
                    .second = second,
                    .third = third,
                };
            };

            try grt.std.testing.expectEqualStrings("line 1\nline 2", parsed.first);
            try grt.std.testing.expectEqualStrings("quote: \"ok\"", parsed.second);
            try grt.std.testing.expectEqualStrings("\xf0\x9f\x98\x80", parsed.third);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.parses_scalars_and_whitespace(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.slices_nested_values(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.decodes_escaped_strings(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
