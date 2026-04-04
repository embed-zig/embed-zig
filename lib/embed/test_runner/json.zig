//! JSON compatibility runner — exercises the `embed.json` std-shaped surface.
//!
//! Usage:
//!   try @import("embed").test_runner.json.run(std);
//!   try @import("embed").test_runner.json.run(embed);

pub fn run(comptime lib: type) !void {
    try parseFromSliceStructTests(lib, lib.testing.allocator);
    try parseFromValueTests(lib, lib.testing.allocator);
    try scannerTests(lib, lib.testing.allocator);
    try readerBackedParseTests(lib, lib.testing.allocator);
    try stringifyTests(lib);
}

fn parseFromSliceStructTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Config = struct {
        name: []const u8,
        enabled: bool,
        count: u8 = 9,
        tags: []const []const u8,
    };

    var parsed = try lib.json.parseFromSlice(
        Config,
        allocator,
        "{\"name\":\"sensor\",\"enabled\":true,\"tags\":[\"rx\",\"tx\"]}",
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("sensor", parsed.value.name);
    try testing.expect(parsed.value.enabled);
    try testing.expectEqual(@as(u8, 9), parsed.value.count);
    try testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try testing.expectEqualStrings("rx", parsed.value.tags[0]);
    try testing.expectEqualStrings("tx", parsed.value.tags[1]);
}

fn parseFromValueTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Payload = struct {
        count: u8,
        label: []const u8,
    };

    var parsed_value = try lib.json.parseFromSlice(
        lib.json.Value,
        allocator,
        "{\"count\":7,\"label\":\"ready\"}",
        .{},
    );
    defer parsed_value.deinit();

    switch (parsed_value.value) {
        .object => |object| {
            const count_value = object.get("count") orelse return error.MissingCount;
            const label_value = object.get("label") orelse return error.MissingLabel;

            switch (count_value) {
                .integer => |count| try testing.expectEqual(@as(i64, 7), count),
                else => return error.UnexpectedCountType,
            }
            switch (label_value) {
                .string => |label| try testing.expectEqualStrings("ready", label),
                else => return error.UnexpectedLabelType,
            }
        },
        else => return error.ExpectedObjectValue,
    }

    var typed = try lib.json.parseFromValue(Payload, allocator, parsed_value.value, .{});
    defer typed.deinit();

    try testing.expectEqual(@as(u8, 7), typed.value.count);
    try testing.expectEqualStrings("ready", typed.value.label);
}

fn scannerTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;

    var scanner = lib.json.Scanner.initCompleteInput(allocator, "{\"sensor\":123,\"ok\":true}");
    defer scanner.deinit();

    try testing.expectEqual(lib.json.Token.object_begin, try scanner.next());

    switch (try scanner.next()) {
        .string => |name| try testing.expectEqualStrings("sensor", name),
        else => return error.ExpectedSensorKey,
    }
    switch (try scanner.next()) {
        .number => |number| try testing.expectEqualStrings("123", number),
        else => return error.ExpectedSensorValue,
    }
    switch (try scanner.next()) {
        .string => |name| try testing.expectEqualStrings("ok", name),
        else => return error.ExpectedOkKey,
    }
    try testing.expectEqual(lib.json.Token.true, try scanner.next());
    try testing.expectEqual(lib.json.Token.object_end, try scanner.next());
    try testing.expectEqual(lib.json.Token.end_of_document, try scanner.next());
}

fn readerBackedParseTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Packet = struct {
        sensor: []const u8,
        sample_rate: u8,
    };

    var io_reader: lib.Io.Reader = .fixed("{\"sensor\":\"temp\",\"sample_rate\":50}");
    var reader = lib.json.Reader.init(allocator, &io_reader);
    defer reader.deinit();

    var parsed = try lib.json.parseFromTokenSource(Packet, allocator, &reader, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("temp", parsed.value.sensor);
    try testing.expectEqual(@as(u8, 50), parsed.value.sample_rate);
}

fn stringifyTests(comptime lib: type) !void {
    const testing = lib.testing;

    var out_buf: [256]u8 = undefined;
    var out: lib.Io.Writer = .fixed(&out_buf);
    var stream: lib.json.Stringify = .{
        .writer = &out,
        .options = .{ .whitespace = .minified },
    };

    try stream.beginObject();
    try stream.objectField("value");
    try stream.write(@as(u8, 42));
    try stream.objectField("flags");
    try stream.beginArray();
    try stream.write(true);
    try stream.write(false);
    try stream.endArray();
    try stream.endObject();

    try testing.expectEqualStrings("{\"value\":42,\"flags\":[true,false]}", out.buffered());

    const Msg = struct {
        ready: bool,
        name: []const u8,
    };

    var fmt_buf: [256]u8 = undefined;
    const rendered = try lib.fmt.bufPrint(
        &fmt_buf,
        "{f}",
        .{lib.json.fmt(Msg{ .ready = true, .name = "rx" }, .{})},
    );
    try testing.expectEqualStrings("{\"ready\":true,\"name\":\"rx\"}", rendered);
}
