const embed = @import("embed");
const testing = embed.testing;
const std = @import("std");
const openapi = @import("openapi");

pub const Phase = enum {
    spec,
    additional_properties,
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
            try std.testing.expectEqualStrings("", spec.info.title);
            try std.testing.expectEqualStrings("", spec.info.version);
            try std.testing.expectEqual(@as(usize, 0), spec.paths.len);
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 23), components.schemas.len);
            const _sor_WithAnyAdditional1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithAnyAdditional1") orelse return error.FixtureMismatch;
            switch (_sor_WithAnyAdditional1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_WithAnyAdditional2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithAnyAdditional2") orelse return error.FixtureMismatch;
            switch (_sor_WithAnyAdditional2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_WithStringAdditional1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithStringAdditional1") orelse return error.FixtureMismatch;
            switch (_sor_WithStringAdditional1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_WithStringAdditional2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithStringAdditional2") orelse return error.FixtureMismatch;
            switch (_sor_WithStringAdditional2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_WithoutAdditional1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithoutAdditional1") orelse return error.FixtureMismatch;
            switch (_sor_WithoutAdditional1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_WithoutAdditional2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "WithoutAdditional2") orelse return error.FixtureMismatch;
            switch (_sor_WithoutAdditional2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_DefaultAdditional1 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "DefaultAdditional1") orelse return error.FixtureMismatch;
            switch (_sor_DefaultAdditional1) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_DefaultAdditional2 = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "DefaultAdditional2") orelse return error.FixtureMismatch;
            switch (_sor_DefaultAdditional2) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 2), sch.properties.len);
                },
            }
            const _sor_MergeWithoutWithout = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithoutWithout") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithoutWithout) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithoutWithString = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithoutWithString") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithoutWithString) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithoutWithAny = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithoutWithAny") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithoutWithAny) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithoutDefault = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithoutDefault") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithoutDefault) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithStringWithout = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithStringWithout") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithStringWithout) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithStringWithAny = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithStringWithAny") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithStringWithAny) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithStringDefault = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithStringDefault") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithStringDefault) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithAnyWithout = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithAnyWithout") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithAnyWithout) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithAnyWithString = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithAnyWithString") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithAnyWithString) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithAnyWithAny = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithAnyWithAny") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithAnyWithAny) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeWithAnyDefault = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeWithAnyDefault") orelse return error.FixtureMismatch;
            switch (_sor_MergeWithAnyDefault) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeDefaultWithout = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeDefaultWithout") orelse return error.FixtureMismatch;
            switch (_sor_MergeDefaultWithout) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeDefaultWithString = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeDefaultWithString") orelse return error.FixtureMismatch;
            switch (_sor_MergeDefaultWithString) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeDefaultWithAny = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeDefaultWithAny") orelse return error.FixtureMismatch;
            switch (_sor_MergeDefaultWithAny) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
                },
            }
            const _sor_MergeDefaultDefault = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "MergeDefaultDefault") orelse return error.FixtureMismatch;
            switch (_sor_MergeDefaultDefault) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqual(@as(usize, 2), sch.all_of.len);
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
        .additional_properties => testing.TestRunner.fromFn(std, 1024 * 1024, struct {
            fn run(t: *testing.T, allocator: std.mem.Allocator) !void {
                _ = t;
                _ = allocator;
                const has_any = comptime blk: {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "spec.json", .spec = openapi.json.parse(@embedFile("spec.json")) },
                        },
                    };
                    const Generated = @import("codegen").models.make(files);
                    break :blk @hasField(Generated.WithAnyAdditional1, "additional_properties");
                };
                const has_string = comptime blk: {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "spec.json", .spec = openapi.json.parse(@embedFile("spec.json")) },
                        },
                    };
                    const Generated = @import("codegen").models.make(files);
                    break :blk @hasField(Generated.WithStringAdditional1, "additional_properties");
                };
                const has_without = comptime blk: {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "spec.json", .spec = openapi.json.parse(@embedFile("spec.json")) },
                        },
                    };
                    const Generated = @import("codegen").models.make(files);
                    break :blk @hasField(Generated.WithoutAdditional1, "additional_properties");
                };

                try std.testing.expect(has_any);
                try std.testing.expect(has_string);
                try std.testing.expect(!has_without);
            }
        }.run),
    };
}
