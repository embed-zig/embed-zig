const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const embed_dep = b.dependency("embed_zig", .{});
    const embed_mod = embed_dep.module("embed");
    const embed_std_mod = embed_dep.module("embed_std");

    const openapi_mod = b.addModule("openapi", .{
        .root_source_file = b.path("lib/openapi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codegen_mod = b.addModule("codegen", .{
        .root_source_file = b.path("lib/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });
    const oapi_codegen_fixtures_mod = b.createModule(.{
        .root_source_file = b.path("tests/oapi-codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
            .{ .name = "helpers", .module = b.createModule(.{
                .root_source_file = b.path("tests/oapi-codegen/helpers.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "openapi", .module = openapi_mod },
                },
            }) },
        },
    });
    const oapi_codegen_fixtures_tests = b.addTest(.{
        .root_module = oapi_codegen_fixtures_mod,
    });
    const run_oapi_codegen_fixtures_tests = b.addRunArtifact(oapi_codegen_fixtures_tests);

    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/sse_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });
    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const examples_mod = b.createModule(.{
        .root_source_file = b.path("tests/examples.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });
    const examples_tests = b.addTest(.{
        .root_module = examples_mod,
    });
    const run_examples_tests = b.addRunArtifact(examples_tests);

    const stream_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/stream_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "codegen", .module = codegen_mod },
            .{ .name = "embed", .module = embed_mod },
            .{ .name = "embed_std", .module = embed_std_mod },
        },
    });
    const stream_tests = b.addTest(.{
        .root_module = stream_tests_mod,
    });
    const run_stream_tests = b.addRunArtifact(stream_tests);

    const test_step = b.step("test", "Run repository tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_examples_tests.step);
    test_step.dependOn(&run_stream_tests.step);
    test_step.dependOn(&run_oapi_codegen_fixtures_tests.step);

    const unit_step = b.step("unit", "Run unit tests");
    unit_step.dependOn(&run_unit_tests.step);

    const example_step = b.step("example", "Run example tests (e.g. petstore integration)");
    example_step.dependOn(&run_examples_tests.step);
    example_step.dependOn(&run_stream_tests.step);
}
