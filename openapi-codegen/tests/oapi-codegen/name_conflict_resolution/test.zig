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
            try std.testing.expectEqualStrings("Comprehensive name collision resolution test", spec.info.title);
            try std.testing.expectEqualStrings("0.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 13), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/foo") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("postFoo", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), post_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/items") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("listItems", get_op.operation_id orelse return error.FixtureMismatch);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createItem", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/query") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("query", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/status") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getStatus", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/qux") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getQux", get_op.operation_id orelse return error.FixtureMismatch);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("postQux", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/zap") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getZap", get_op.operation_id orelse return error.FixtureMismatch);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("postZap", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/orders") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createOrder", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/entities") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("listEntities", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/resources/{id}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const patch_op = p_it.patch orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("patchResource", patch_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), patch_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/renamed-schema") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getRenamedSchema", get_op.operation_id orelse return error.FixtureMismatch);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("postRenamedSchema", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/outcome") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getOutcome", get_op.operation_id orelse return error.FixtureMismatch);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("postOutcome", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/payload") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("sendPayload", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pets") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createPet", post_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 18), components.schemas.len);
            const _sor_Bar = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Bar") orelse return error.FixtureMismatch;
            switch (_sor_Bar) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Bar2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Bar2") orelse return error.FixtureMismatch;
            switch (_sor_Bar2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_CreateItemResponse = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "CreateItemResponse") orelse return error.FixtureMismatch;
            switch (_sor_CreateItemResponse) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_ListItemsResponse = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ListItemsResponse") orelse return error.FixtureMismatch;
            switch (_sor_ListItemsResponse) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_QueryResponse = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "QueryResponse") orelse return error.FixtureMismatch;
            switch (_sor_QueryResponse) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_GetStatusResponse = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "GetStatusResponse") orelse return error.FixtureMismatch;
            switch (_sor_GetStatusResponse) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_Order = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Order") orelse return error.FixtureMismatch;
            switch (_sor_Order) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_Pet = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Pet") orelse return error.FixtureMismatch;
            switch (_sor_Pet) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_Widget = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Widget") orelse return error.FixtureMismatch;
            switch (_sor_Widget) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Metadata = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Metadata") orelse return error.FixtureMismatch;
            switch (_sor_Metadata) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Resource_MVO = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Resource_MVO") orelse return error.FixtureMismatch;
            switch (_sor_Resource_MVO) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_Resource = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Resource") orelse return error.FixtureMismatch;
            switch (_sor_Resource) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                },
            }
            const _sor_JsonPatch = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "JsonPatch") orelse return error.FixtureMismatch;
            switch (_sor_JsonPatch) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("array", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_Renamer = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Renamer") orelse return error.FixtureMismatch;
            switch (_sor_Renamer) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Outcome = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Outcome") orelse return error.FixtureMismatch;
            switch (_sor_Outcome) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Payload = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Payload") orelse return error.FixtureMismatch;
            switch (_sor_Payload) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Qux = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Qux") orelse return error.FixtureMismatch;
            switch (_sor_Qux) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_Zap = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Zap") orelse return error.FixtureMismatch;
            switch (_sor_Zap) {
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

