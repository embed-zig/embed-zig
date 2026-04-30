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
            try std.testing.expectEqualStrings("3.0.1", spec.openapi);
            try std.testing.expectEqualStrings("example", spec.info.title);
            try std.testing.expectEqualStrings("0.0.1", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/example") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const patch_op = p_it.patch orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("examplePatch", patch_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 6), components.schemas.len);
            const _sor_PatchRequest = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "PatchRequest") orelse return error.FixtureMismatch;
            switch (_sor_PatchRequest) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 5), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_simple_required_nullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "simple_required_nullable") orelse return error.FixtureMismatch;
            switch (_sor_simple_required_nullable) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("integer", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_simple_optional_nullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "simple_optional_nullable") orelse return error.FixtureMismatch;
            switch (_sor_simple_optional_nullable) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("integer", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_simple_optional_non_nullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "simple_optional_non_nullable") orelse return error.FixtureMismatch;
            switch (_sor_simple_optional_non_nullable) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_complex_required_nullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "complex_required_nullable") orelse return error.FixtureMismatch;
            switch (_sor_complex_required_nullable) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_complex_optional_nullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "complex_optional_nullable") orelse return error.FixtureMismatch;
            switch (_sor_complex_optional_nullable) {
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

    return testing.TestRunner.make(Runner).new(&holder.state);
}

