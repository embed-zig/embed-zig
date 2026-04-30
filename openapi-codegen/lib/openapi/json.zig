const std = @import("std");
const Spec = @import("Spec.zig");
const json_parser = @import("json/parser.zig");
const json_stringify = @import("json/stringify.zig");

const Allocator = std.mem.Allocator;

pub fn parse(comptime source: []const u8) Spec {
    return json_parser.parseComptime(source);
}

pub fn parseAlloc(allocator: Allocator, source: []const u8) !Spec {
    return json_parser.parse(allocator, source);
}

pub fn stringifyAlloc(allocator: Allocator, spec: Spec) ![]u8 {
    return json_stringify.stringifyAlloc(allocator, spec);
}
