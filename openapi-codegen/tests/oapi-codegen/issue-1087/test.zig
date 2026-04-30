const std = @import("std");
const testing = embed.testing;
const helpers = @import("helpers");
const codegen_helpers = @import("../codegen_helpers.zig");
const openapi = @import("openapi");
const embed = @import("embed");
const lib = @import("embed_std").std;

pub const Phase = enum {
    spec,
    external_response_refs,
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
            try std.testing.expectEqualStrings("3.0.3", spec.openapi);
            try std.testing.expectEqualStrings("test", spec.info.title);
            try std.testing.expectEqualStrings("2.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/api/my/path") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqualStrings("getThings", get_op.operation_id orelse return error.FixtureMismatch);
            }
            const components = spec.components orelse return error.FixtureMismatch;
            try std.testing.expectEqual(@as(usize, 2), components.schemas.len);
            const _sor_Thing = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "Thing") orelse return error.FixtureMismatch;
            switch (_sor_Thing) {
                .reference => |r| {
                    _ = r.ref_path;
                },
                .schema => |sch| {
                    try std.testing.expectEqualStrings("object", sch.schema_type orelse return error.FixtureMismatch);
                    try std.testing.expectEqual(@as(usize, 1), sch.properties.len);
                    try std.testing.expectEqual(@as(usize, 1), sch.required.len);
                },
            }
            const _sor_ThingList = Spec.findNamed(Spec.SchemaOrRef, components.schemas, "ThingList") orelse return error.FixtureMismatch;
            switch (_sor_ThingList) {
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
        .external_response_refs => testing.TestRunner.fromFn(std, 1024 * 1024, struct {
            fn run(t: *testing.T, allocator: std.mem.Allocator) !void {
                _ = t;
                _ = allocator;
                comptime {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "spec.json", .spec = openapi.json.parse(@embedFile("spec.json")) },
                            .{ .name = "./deps/my-deps.json", .spec = openapi.json.parse(@embedFile("deps/my-deps/spec.json")) },
                        },
                    };

                    codegen_helpers.assertClientServerCompile(lib, files);
                }
            }
        }.run),
    };
}
