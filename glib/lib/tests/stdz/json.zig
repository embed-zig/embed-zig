//! JSON compatibility runner — exercises the `stdz.json` std-shaped surface.
//!
//! Usage:
//!   try @import("std/tests/stdz/json.zig").run(std);
//!   try @import("std/tests/stdz/json.zig").run(stdz);

const stdz = @import("stdz");
const host_std = @import("std");
const testing_mod = @import("testing");

pub fn make(comptime std: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("declaration_parity", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try jsonDeclarationParityCase(std);
                }
            }.run));
            t.run("type_identity", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try jsonTypeIdentityCase(std);
                }
            }.run));
            t.run("parse_from_slice_struct", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    try parseFromSliceStructTests(std, sub_allocator);
                }
            }.run));
            t.run("parse_from_value", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    try parseFromValueTests(std, sub_allocator);
                }
            }.run));
            t.run("scanner", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    try scannerTests(std, sub_allocator);
                }
            }.run));
            t.run("reader_backed_parse", testing_mod.TestRunner.fromFn(std, 40 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    try readerBackedParseTests(std, sub_allocator);
                }
            }.run));
            t.run("stringify", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try stringifyTests(std);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

const json = @This();

fn jsonDeclarationParityCase(comptime std: type) !void {
    inline for (comptime host_std.meta.declarations(host_std.json)) |decl| {
        try std.testing.expect(@hasDecl(stdz.json, decl.name));
    }
    inline for (comptime host_std.meta.declarations(stdz.json)) |decl| {
        try std.testing.expect(@hasDecl(host_std.json, decl.name));
    }
}

fn jsonTypeIdentityCase(comptime std: type) !void {
    try std.testing.expect(stdz.json.ObjectMap == host_std.json.ObjectMap);
    try std.testing.expect(stdz.json.Array == host_std.json.Array);
    try std.testing.expect(stdz.json.Value == host_std.json.Value);
    try std.testing.expect(stdz.json.ArrayHashMap == host_std.json.ArrayHashMap);
    try std.testing.expect(stdz.json.Scanner == host_std.json.Scanner);
    try std.testing.expect(stdz.json.Reader == host_std.json.Reader);
    try std.testing.expect(stdz.json.Token == host_std.json.Token);
    try std.testing.expect(stdz.json.ParseOptions == host_std.json.ParseOptions);
    try std.testing.expect(stdz.json.Stringify == host_std.json.Stringify);
    try std.testing.expect(@TypeOf(stdz.json.parseFromSlice) == @TypeOf(host_std.json.parseFromSlice));
    try std.testing.expect(@TypeOf(stdz.json.parseFromTokenSource) == @TypeOf(host_std.json.parseFromTokenSource));
    try std.testing.expect(@TypeOf(stdz.json.parseFromValue) == @TypeOf(host_std.json.parseFromValue));
    try std.testing.expect(@TypeOf(stdz.json.fmt) == @TypeOf(host_std.json.fmt));
    try std.testing.expect(@TypeOf(stdz.json.Formatter) == @TypeOf(host_std.json.Formatter));
}

pub fn run(comptime std: type) !void {
    try parseFromSliceStructTests(std, std.testing.allocator);
    try parseFromValueTests(std, std.testing.allocator);
    try scannerTests(std, std.testing.allocator);
    try readerBackedParseTests(std, std.testing.allocator);
    try stringifyTests(std);
}

fn parseFromSliceStructTests(comptime std: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Config = struct {
        name: []const u8,
        enabled: bool,
        count: u8 = 9,
        tags: []const []const u8,
    };

    var parsed = try std.json.parseFromSlice(
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

fn parseFromValueTests(comptime std: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Payload = struct {
        count: u8,
        label: []const u8,
    };

    var parsed_value = try std.json.parseFromSlice(
        std.json.Value,
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

    var typed = try std.json.parseFromValue(Payload, allocator, parsed_value.value, .{});
    defer typed.deinit();

    try testing.expectEqual(@as(u8, 7), typed.value.count);
    try testing.expectEqualStrings("ready", typed.value.label);
}

fn scannerTests(comptime std: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;

    var scanner = std.json.Scanner.initCompleteInput(allocator, "{\"sensor\":123,\"ok\":true}");
    defer scanner.deinit();

    try testing.expectEqual(std.json.Token.object_begin, try scanner.next());

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
    try testing.expectEqual(std.json.Token.true, try scanner.next());
    try testing.expectEqual(std.json.Token.object_end, try scanner.next());
    try testing.expectEqual(std.json.Token.end_of_document, try scanner.next());
}

fn readerBackedParseTests(comptime std: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Packet = struct {
        sensor: []const u8,
        sample_rate: u8,
    };

    var io_reader: std.Io.Reader = .fixed("{\"sensor\":\"temp\",\"sample_rate\":50}");
    var reader = std.json.Reader.init(allocator, &io_reader);
    defer reader.deinit();

    var parsed = try std.json.parseFromTokenSource(Packet, allocator, &reader, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("temp", parsed.value.sensor);
    try testing.expectEqual(@as(u8, 50), parsed.value.sample_rate);
}

fn stringifyTests(comptime std: type) !void {
    const testing = std.testing;

    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var stream: std.json.Stringify = .{
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
    const rendered = try std.fmt.bufPrint(
        &fmt_buf,
        "{f}",
        .{std.json.fmt(Msg{ .ready = true, .name = "rx" }, .{})},
    );
    try testing.expectEqualStrings("{\"ready\":true,\"name\":\"rx\"}", rendered);
}
