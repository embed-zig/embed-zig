const std = @import("std");
const embed = @import("embed");
const testing = embed.testing;
const openapi = @import("openapi");

pub fn TestRunner() testing.TestRunner {
    const Runner = struct {
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn run(_: *@This(), t: *testing.T, allocator: std.mem.Allocator) bool {
            checkFixture(allocator) catch |e| {
                t.logFatal(@errorName(e));
                return false;
            };
            return true;
        }

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

        fn checkFixture(allocator: std.mem.Allocator) !void {
            const Spec = openapi.Spec;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const spec = try openapi.json.parseAlloc(a, @embedFile("spec.json"));
            try std.testing.expectEqualStrings("3.0.3", spec.openapi);
            try std.testing.expectEqualStrings("Models", spec.info.title);
            try std.testing.expectEqualStrings("2.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 0), spec.paths.len);
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 2), components.schemas.len);
            const _sor_Error = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Error") orelse return error.FixtureMismatch;
            switch (_sor_Error) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.all_of.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 4), sch.required.len);
                },
            }
            const _sor_BaseError = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "BaseError") orelse return error.FixtureMismatch;
            switch (_sor_BaseError) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 4), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 3), sch.required.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

