const std = @import("std");
const testing = embed.testing;
const helpers = @import("helpers");
const codegen_helpers = @import("../../codegen_helpers.zig");
const openapi = @import("openapi");
const embed = @import("embed");
const lib = @import("embed_std").std;

pub const Phase = enum {
    spec,
    compile_heavy,
};

fn specRunner() testing.TestRunner {
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
            try std.testing.expectEqual(@as(usize, 2), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/ensure-everything-is-referenced") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("ensureEverythingIsReferenced", get_op.operation_id orelse return error.FixtureMismatch);
            }
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/params_with_add_props") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("ParamsWithAddProps", get_op.operation_id orelse return error.FixtureMismatch);
                try std.testing.expectEqual(@as(usize, 2), get_op.parameters.len);
                const post_op = p_it.post orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("BodyWithAddProps", post_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 43), components.schemas.len);
            const _sor_SchemaObject = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "SchemaObject") orelse return error.FixtureMismatch;
            switch (_sor_SchemaObject) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 4), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 4), sch.required.len);
                },
            }
            const _sor_SchemaObjectNullable = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "SchemaObjectNullable") orelse return error.FixtureMismatch;
            switch (_sor_SchemaObjectNullable) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 4), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 4), sch.required.len);
                },
            }
            const _sor_AdditionalPropertiesObject1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject1") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_AdditionalPropertiesObject2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject2") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_AdditionalPropertiesObject3 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject3") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject3) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_AdditionalPropertiesObject4 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject4") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject4) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_AdditionalPropertiesObject5 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject5") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject5) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_AdditionalPropertiesObject6 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject6") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject6) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("array", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_AdditionalPropertiesObject7 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AdditionalPropertiesObject7") orelse return error.FixtureMismatch;
            switch (_sor_AdditionalPropertiesObject7) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_OneOfObject1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject1") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 3), sch.one_of.len);
                },
            }
            const _sor_OneOfObject2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject2") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 3), sch.one_of.len);
                },
            }
            const _sor_OneOfObject3 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject3") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject3) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_OneOfObject4 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject4") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject4) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.one_of.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_OneOfObject5 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject5") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject5) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                },
            }
            const _sor_OneOfObject6 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject6") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject6) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                },
            }
            const _sor_OneOfObject61 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject61") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject61) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                },
            }
            const _sor_OneOfObject62 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject62") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject62) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                },
            }
            const _sor_OneOfObject7 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject7") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject7) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("array", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_OneOfObject8 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject8") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject8) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                },
            }
            const _sor_OneOfObject9 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject9") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject9) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_OneOfObject10 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject10") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject10) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                },
            }
            const _sor_OneOfObject11 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject11") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject11) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_OneOfObject12 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject12") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject12) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_OneOfObject13 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfObject13") orelse return error.FixtureMismatch;
            switch (_sor_OneOfObject13) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.one_of.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_AnyOfObject1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "AnyOfObject1") orelse return error.FixtureMismatch;
            switch (_sor_AnyOfObject1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.any_of.len);
                },
            }
            const _sor_OneOfVariant1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant1") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_OneOfVariant2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant2") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("array", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_OneOfVariant3 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant3") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant3) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("boolean", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_OneOfVariant4 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant4") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant4) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_OneOfVariant5 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant5") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant5) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_one_of_variant51 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "one_of_variant51") orelse return error.FixtureMismatch;
            switch (_sor_one_of_variant51) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_OneOfVariant6 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "OneOfVariant6") orelse return error.FixtureMismatch;
            switch (_sor_OneOfVariant6) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_ObjectWithJsonField = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ObjectWithJsonField") orelse return error.FixtureMismatch;
            switch (_sor_ObjectWithJsonField) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 3), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_Enum1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Enum1") orelse return error.FixtureMismatch;
            switch (_sor_Enum1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_Enum2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Enum2") orelse return error.FixtureMismatch;
            switch (_sor_Enum2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_Enum3 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Enum3") orelse return error.FixtureMismatch;
            switch (_sor_Enum3) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_Enum4 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Enum4") orelse return error.FixtureMismatch;
            switch (_sor_Enum4) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_Enum5 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Enum5") orelse return error.FixtureMismatch;
            switch (_sor_Enum5) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("integer", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_EnumUnion = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "EnumUnion") orelse return error.FixtureMismatch;
            switch (_sor_EnumUnion) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_EnumUnion2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "EnumUnion2") orelse return error.FixtureMismatch;
            switch (_sor_EnumUnion2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_FunnyValues = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "FunnyValues") orelse return error.FixtureMismatch;
            switch (_sor_FunnyValues) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("string", sch.schema_type orelse return error.FixtureMismatch);
                },
            }
            const _sor_RenameMe = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "RenameMe") orelse return error.FixtureMismatch;
            switch (_sor_RenameMe) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 2), sch.required.len);
                },
            }
            const _sor_ReferenceToRenameMe = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ReferenceToRenameMe") orelse return error.FixtureMismatch;
            switch (_sor_ReferenceToRenameMe) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
        }
    };

    const holder = struct {
        var state: Runner = .{};
    };

    return testing.TestRunner.make(Runner).new(&holder.state);
}

pub fn TestRunner(comptime phase: Phase) testing.TestRunner {
    return switch (phase) {
        .spec => specRunner(),
        .compile_heavy => testing.TestRunner.fromFn(std, 1024 * 1024, struct {
            fn run(t: *testing.T, allocator: std.mem.Allocator) !void {
                _ = t;
                _ = allocator;
                comptime {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "spec.json", .spec = openapi.json.parse(@embedFile("spec.json")) },
                        },
                    };

                    codegen_helpers.assertClientServerCompile(lib, files);
                }
            }
        }.run),
    };
}
