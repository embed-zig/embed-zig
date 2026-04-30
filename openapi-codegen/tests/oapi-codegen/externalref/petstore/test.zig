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
            try std.testing.expectEqualStrings("Swagger Petstore - OpenAPI 3.0", spec.info.title);
            try std.testing.expectEqualStrings("1.0.17", spec.info.version);
            try std.testing.expectEqual(@as(usize, 13), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pet") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("addPet", post_op.operation_id orelse return error.FixtureMismatch);
                const put_op = p_it.put orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("updatePet", put_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pet/findByStatus") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("findPetsByStatus", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pet/findByTags") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("findPetsByTags", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pet/{petId}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getPetById", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("updatePetWithForm", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 3), post_op.parameters.len);
                const delete_op = p_it.delete orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("deletePet", delete_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), delete_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pet/{petId}/uploadImage") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("uploadFile", post_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), post_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/store/inventory") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getInventory", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/store/order") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("placeOrder", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/store/order/{orderId}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getOrderById", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
                const delete_op = p_it.delete orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("deleteOrder", delete_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), delete_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/user") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createUser", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/user/createWithList") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("createUsersWithListInput", post_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/user/login") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("loginUser", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/user/logout") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("logoutUser", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 0), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/user/{username}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getUserByName", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
                const put_op = p_it.put orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("updateUser", put_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), put_op.parameters.len);
                const delete_op = p_it.delete orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("deleteUser", delete_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), delete_op.parameters.len);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 8), components.schemas.len);
            const _sor_Order = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Order") orelse return error.FixtureMismatch;
            switch (_sor_Order) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 6), sch.properties.len);
                },
            }
            const _sor_Customer = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Customer") orelse return error.FixtureMismatch;
            switch (_sor_Customer) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                },
            }
            const _sor_Address = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Address") orelse return error.FixtureMismatch;
            switch (_sor_Address) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 4), sch.properties.len);
                },
            }
            const _sor_Category = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Category") orelse return error.FixtureMismatch;
            switch (_sor_Category) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_User = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "User") orelse return error.FixtureMismatch;
            switch (_sor_User) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 8), sch.properties.len);
                },
            }
            const _sor_Tag = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Tag") orelse return error.FixtureMismatch;
            switch (_sor_Tag) {
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
                    try std.testing.expectEqual(@as(usize, 6), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_ApiResponse = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ApiResponse") orelse return error.FixtureMismatch;
            switch (_sor_ApiResponse) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

