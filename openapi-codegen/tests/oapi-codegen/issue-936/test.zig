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
            try std.testing.expectEqualStrings("Deep recursive cyclic refs example", spec.info.title);
            try std.testing.expectEqualStrings("1.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/foo") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                _ = p_it;
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 6), components.schemas.len);
            const _sor_FilterColumnIncludes = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterColumnIncludes") orelse return error.FixtureMismatch;
            switch (_sor_FilterColumnIncludes) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_FilterPredicate = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterPredicate") orelse return error.FixtureMismatch;
            switch (_sor_FilterPredicate) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 4), sch.one_of.len);
                },
            }
            const _sor_FilterPredicateOp = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterPredicateOp") orelse return error.FixtureMismatch;
            switch (_sor_FilterPredicateOp) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_FilterPredicateRangeOp = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterPredicateRangeOp") orelse return error.FixtureMismatch;
            switch (_sor_FilterPredicateRangeOp) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_FilterRangeValue = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterRangeValue") orelse return error.FixtureMismatch;
            switch (_sor_FilterRangeValue) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                },
            }
            const _sor_FilterValue = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FilterValue") orelse return error.FixtureMismatch;
            switch (_sor_FilterValue) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 3), sch.one_of.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

