const std = @import("std");
const portaudio_pkg = @import("third_party/portaudio/lib.zig");
const speexdsp_pkg = @import("third_party/speexdsp/lib.zig");
const opus_pkg = @import("third_party/opus/lib.zig");
const ogg_pkg = @import("third_party/ogg/lib.zig");
const stb_truetype_pkg = @import("third_party/stb_truetype/lib.zig");
const audio_engine_build = @import("src/bin/audio_engine/build.zig");
const bleterm_build = @import("src/bin/bleterm/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -- Third-party (module + static library) --
    const pa = portaudio_pkg.addTo(b, target, optimize);
    const spx = speexdsp_pkg.addTo(b, target, optimize);
    const opus = opus_pkg.addTo(b, target, optimize);
    const ogg = ogg_pkg.addTo(b, target, optimize);
    const stb_tt = stb_truetype_pkg.addTo(b, target, optimize);
    const fonts_mod = b.addModule("fonts", .{
        .root_source_file = b.path("third_party/fonts/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const third_party_mod = b.addModule("third_party", .{
        .root_source_file = b.path("third_party/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    third_party_mod.addImport("portaudio", pa.module);
    third_party_mod.addImport("speexdsp", spx.module);
    third_party_mod.addImport("opus", opus.module);
    third_party_mod.addImport("ogg", ogg.module);
    third_party_mod.addImport("stb_truetype", stb_tt.module);
    third_party_mod.addImport("fonts", fonts_mod);

    // ===================================================================
    // Project module
    // ===================================================================

    const embed_mod = b.addModule("embed", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    embed_mod.addImport("third_party", third_party_mod);
    embed_mod.addImport("speexdsp", spx.module);
    embed_mod.addImport("fonts", fonts_mod);
    embed_mod.addImport("stb_truetype", stb_tt.module);

    const files = b.addWriteFiles();
    const empty_root = files.add("empty.zig", "");
    const embed_link_root = b.createModule(.{
        .root_source_file = empty_root,
        .target = target,
        .optimize = optimize,
    });
    const embed_link = b.addLibrary(.{
        .name = "embed_link",
        .linkage = .static,
        .root_module = embed_link_root,
    });
    embed_link.linkLibrary(spx.lib);
    embed_link.linkLibrary(stb_tt.lib);

    embed_link.step.dependOn(spx.repo.ensure_step);

    b.installArtifact(embed_link);
    b.installArtifact(pa.lib);
    b.installArtifact(spx.lib);
    b.installArtifact(opus.lib);
    b.installArtifact(ogg.lib);
    b.installArtifact(stb_tt.lib);

    // ===================================================================
    // Tests
    // ===================================================================

    const project_tests_root = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    project_tests_root.addImport("third_party", third_party_mod);
    project_tests_root.addImport("speexdsp", spx.module);
    project_tests_root.addImport("fonts", fonts_mod);
    project_tests_root.addImport("stb_truetype", stb_tt.module);

    const project_tests = b.addTest(.{
        .root_module = project_tests_root,
    });
    project_tests.linkLibrary(spx.lib);
    project_tests.linkLibrary(stb_tt.lib);
    project_tests.step.dependOn(spx.repo.ensure_step);
    const run_project_tests = b.addRunArtifact(project_tests);

    // ===================================================================
    // Executables
    // ===================================================================

    audio_engine_build.addSteps(b, target, optimize, pa, spx);
    bleterm_build.addSteps(b, target, optimize);

    // ===================================================================
    // Steps
    // ===================================================================

    b.step("test-runtime-std", "Run runtime std tests").dependOn(&run_project_tests.step);
    b.step("test-async", "Run async package tests").dependOn(&run_project_tests.step);
    b.step("test-audio", "Run audio package tests").dependOn(&run_project_tests.step);
    b.step("test-net", "Run net package tests").dependOn(&run_project_tests.step);
    b.step("test-ble", "Run BLE package tests").dependOn(&run_project_tests.step);
    b.step("test-ui", "Run UI tests").dependOn(&run_project_tests.step);
    b.step("test-event", "Run event package tests").dependOn(&run_project_tests.step);
    b.step("test-app", "Run app runtime tests").dependOn(&run_project_tests.step);

    const all = b.step("test", "Run all tests");
    all.dependOn(&run_project_tests.step);
}
