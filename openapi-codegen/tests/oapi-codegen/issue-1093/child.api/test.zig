const std = @import("std");
const testing = embed.testing;
const codegen_helpers = @import("../../codegen_helpers.zig");
const openapi = @import("openapi");
const embed = @import("embed");
const lib = @import("embed_std").std;

pub const Phase = enum {
    spec,
    parent_bundle,
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
            try std.testing.expectEqualStrings("3.0.0", spec.openapi);
            try std.testing.expectEqualStrings("child", spec.info.title);
            try std.testing.expectEqualStrings("1.0", spec.info.version);
            try std.testing.expectEqual(@as(usize, 1), spec.paths.len);
            {
                const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, "/pets") orelse return error.FixtureMismatch;
                const p_it = switch (p_or) {
                    .path_item => |x| x,
                    .reference => return error.FixtureMismatch,
                };
                const get_op = p_it.get orelse return error.FixtureMismatch;
                try std.testing.expectEqual(@as(?[]const u8, null), get_op.operation_id);
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
        .parent_bundle => testing.TestRunner.fromFn(std, 1024 * 1024, struct {
        fn run(t: *testing.T, allocator: std.mem.Allocator) !void {
            _ = t;
            _ = allocator;
            comptime {
                const files: openapi.Files = .{
                    .items = &.{
                        .{ .name = "child.api.yaml", .spec = openapi.json.parse(@embedFile("spec.json")) },
                        .{ .name = "parent.api.yaml", .spec = openapi.json.parse(@embedFile("../parent.api/spec.json")) },
                    },
                };

                codegen_helpers.assertClientServerCompile(lib, files);
            }
        }
        }.run),
    };
}
