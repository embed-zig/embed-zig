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
            try std.testing.expectEqualStrings("Cats, Dogs and Rats API", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pets") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getPets", get_op.operation_id orelse return error.FixtureMismatch);
                {
                    const res_or = Spec.findNamed(Spec.ResponseOrRef, get_op.responses, "200") orelse return error.FixtureMismatch;
                    const res = switch (res_or) {
                        .response => |x| x,
                        .reference => return error.FixtureMismatch,
                    };
                    const mt = Spec.findNamed(Spec.MediaType, res.content, "application/json") orelse return error.FixtureMismatch;
                    const root_sch_ptr = mt.schema orelse return error.FixtureMismatch;
                    const root_sch = switch (root_sch_ptr.*) {
                        .schema => |s| s,
                        .reference => return error.FixtureMismatch,
                    };
                    const data_f = Spec.findNamed(Spec.SchemaOrRef, root_sch.properties, "data") orelse return error.FixtureMismatch;
                    const data_sch = switch (data_f) {
                        .schema => |s| s,
                        .reference => return error.FixtureMismatch,
                    };
                    const items_ptr = data_sch.items orelse return error.FixtureMismatch;
                    const items_sch = switch (items_ptr.*) {
                        .schema => |s| s,
                        .reference => return error.FixtureMismatch,
                    };
                    try std.testing.expectEqual(@as(usize, 3), items_sch.any_of.len);
                }
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 3), components.schemas.len);
            const _sor_Cat = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Cat") orelse return error.FixtureMismatch;
            switch (_sor_Cat) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 5), sch.properties.len);
                },
            }
            const _sor_Dog = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Dog") orelse return error.FixtureMismatch;
            switch (_sor_Dog) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 5), sch.properties.len);
                },
            }
            const _sor_Rat = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Rat") orelse return error.FixtureMismatch;
            switch (_sor_Rat) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 4), sch.properties.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

