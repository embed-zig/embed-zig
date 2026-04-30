const std = @import("std");
const testing = embed.testing;
const helpers = @import("helpers");
const codegen_helpers = @import("../../codegen_helpers.zig");
const openapi = @import("openapi");
const embed = @import("embed");
const lib = @import("embed_std").std;

pub const Phase = enum {
    spec,
    path_refs,
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
            try std.testing.expectEqualStrings("Test", spec.info.title);
            try std.testing.expectEqualStrings("1.0.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/bionicle/{name}") orelse return error.FixtureMismatch;
                const ref = switch (p_or) {
                    .path_item => return error.FixtureMismatch,
                    .reference => |x| x,
                };
                try std.testing.expectEqualStrings(
                    "bionicle.yaml#/paths/~1bionicle~1{name}",
                    ref.ref_path,
                );
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
        .path_refs => testing.TestRunner.fromFn(std, 1024 * 1024, struct {
            fn run(t: *testing.T, allocator: std.mem.Allocator) !void {
                _ = t;
                _ = allocator;
                comptime {
                    const files: openapi.Files = .{
                        .items = &.{
                            .{ .name = "foo-service.yaml", .spec = openapi.json.parse(@embedFile("spec.json")) },
                            .{ .name = "bionicle.yaml", .spec = openapi.json.parse(@embedFile("../bionicle/spec.json")) },
                            .{ .name = "common.yaml", .spec = openapi.json.parse(@embedFile("../common/spec.json")) },
                        },
                    };

                    codegen_helpers.assertClientServerCompile(lib, files);
                }
            }
        }.run),
    };
}
