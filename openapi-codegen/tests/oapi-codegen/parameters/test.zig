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
            try std.testing.expectEqualStrings("Test Server", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 21), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/simplePrimitive/{param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimplePrimitive", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/simpleNoExplodeArray/{param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimpleNoExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/simpleExplodeArray/{param*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimpleExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/simpleNoExplodeObject/{param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimpleNoExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/simpleExplodeObject/{param*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getSimpleExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/labelNoExplodeArray/{.param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getLabelNoExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/labelExplodeArray/{.param*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getLabelExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/labelNoExplodeObject/{.param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getLabelNoExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/labelExplodeObject/{.param*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getLabelExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/matrixNoExplodeArray/{.id}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getMatrixNoExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/matrixExplodeArray/{.id*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getMatrixExplodeArray", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/matrixNoExplodeObject/{.id}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getMatrixNoExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/matrixExplodeObject/{.id*}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getMatrixExplodeObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/contentObject/{param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getContentObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/passThrough/{param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getPassThrough", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/startingWithNumber/{1param}") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getStartingWithNumber", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/queryForm") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getQueryForm", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 9), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/queryDeepObject") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getDeepObject", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/header") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getHeader", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 8), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/cookie") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getCookie", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 8), get_op.parameters.len);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/enums") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("enumParams", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 1), get_op.parameters.len);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 2), components.schemas.len);
            const _sor_Object = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Object") orelse return error.FixtureMismatch;
            switch (_sor_Object) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_ComplexObject = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ComplexObject") orelse return error.FixtureMismatch;
            switch (_sor_ComplexObject) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
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

