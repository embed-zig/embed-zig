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
            try std.testing.expectEqualStrings("3.0.2", spec.openapi);
            try std.testing.expectEqualStrings("example", spec.info.title);
            try std.testing.expectEqualStrings("0.0.1", spec.info.version);
            try std.testing.expectEqual(@as(usize, 2), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/example") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("exampleGet", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/example2") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("exampleGet2", get_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 2), components.schemas.len);
            const _sor_Document = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Document") orelse return error.FixtureMismatch;
            switch (_sor_Document) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_DocumentStatus = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "DocumentStatus") orelse return error.FixtureMismatch;
            switch (_sor_DocumentStatus) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

