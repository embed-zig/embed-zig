const std = @import("std");
const build_tools = @import("../../../third_party/build_tools.zig");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    portaudio: build_tools.ExternalStaticLibraryModule,
    speexdsp: build_tools.ExternalStaticLibraryModule,
) void {
    const embed_mod = b.modules.get("embed").?;
    const audio_root = b.createModule(.{
        .root_source_file = b.path("src/bin/audio_engine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_root.addImport("embed", embed_mod);
    audio_root.addImport("portaudio", portaudio.module);
    audio_root.addImport("speexdsp", speexdsp.module);

    const audio_exe = b.addExecutable(.{
        .name = "audio_engine",
        .root_module = audio_root,
    });
    audio_exe.linkLibrary(portaudio.lib);
    audio_exe.linkLibrary(speexdsp.lib);
    audio_exe.step.dependOn(portaudio.repo.ensure_step);
    audio_exe.step.dependOn(speexdsp.repo.ensure_step);

    const run_audio_exe = b.addRunArtifact(audio_exe);
    if (b.args) |args| run_audio_exe.addArgs(args);

    b.step("audio-engine", "Run audio engine demo").dependOn(&run_audio_exe.step);
    b.step("build-audio-engine", "Build audio engine demo").dependOn(&audio_exe.step);
}
