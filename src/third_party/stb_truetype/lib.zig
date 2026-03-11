const std = @import("std");

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const files = b.addWriteFiles();
    const empty_root = files.add("empty.zig", "");
    const lib = b.addLibrary(.{
        .name = "stb_truetype",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = empty_root,
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
        }),
    });
    lib.linkLibC();
    lib.addIncludePath(b.path("src/third_party/stb_truetype"));
    lib.addCSourceFile(.{ .file = b.path("src/third_party/stb_truetype/stb_truetype_impl.c") });

    return lib;
}

pub fn configureModule(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/third_party/stb_truetype"));
}
