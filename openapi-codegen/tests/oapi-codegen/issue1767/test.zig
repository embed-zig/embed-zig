const std = @import("std");
const glib = @import("glib");
const openapi = @import("openapi");

pub fn TestRunner() glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn run(_: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
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
            try std.testing.expectEqualStrings("3.0.0", spec.openapi);
            try std.testing.expectEqualStrings("An underscore in the name of a field is remapped to `Underscore`", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 0), spec.paths.len);
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 1), components.schemas.len);
            const _sor_Alarm = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Alarm") orelse return error.FixtureMismatch;
            switch (_sor_Alarm) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return glib.testing.TestRunner.make(Runner).new(&holder.state);
}
