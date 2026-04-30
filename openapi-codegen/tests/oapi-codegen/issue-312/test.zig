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
            try std.testing.expectEqualStrings("3.0.0", spec.openapi);
            try std.testing.expectEqualStrings("Issue 312 test", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 2), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pets:validate") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("validatePets", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pets/{petId}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getPet", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 3), components.schemas.len);
            const _sor_Pet = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Pet") orelse return error.FixtureMismatch;
            switch (_sor_Pet) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_PetNames = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "PetNames") orelse return error.FixtureMismatch;
            switch (_sor_PetNames) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_Error = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Error") orelse return error.FixtureMismatch;
            switch (_sor_Error) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

