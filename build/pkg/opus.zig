const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;

const include_dirs: []const []const u8 = &.{
    "celt",
    "include",
    "silk",
    "silk/fixed",
    "src",
};

const c_sources: []const []const u8 = &.{
    "src/opus.c",
    "src/opus_decoder.c",
    "src/opus_encoder.c",
    "src/analysis.c",
    "src/extensions.c",
    "src/mlp.c",
    "src/mlp_data.c",
    "src/opus_multistream.c",
    "src/opus_multistream_encoder.c",
    "src/opus_multistream_decoder.c",
    "src/repacketizer.c",
    "src/opus_projection_encoder.c",
    "src/opus_projection_decoder.c",
    "src/mapping_matrix.c",
    "celt/bands.c",
    "celt/celt.c",
    "celt/celt_encoder.c",
    "celt/celt_decoder.c",
    "celt/cwrs.c",
    "celt/entcode.c",
    "celt/entdec.c",
    "celt/entenc.c",
    "celt/kiss_fft.c",
    "celt/laplace.c",
    "celt/mathops.c",
    "celt/mdct.c",
    "celt/modes.c",
    "celt/pitch.c",
    "celt/celt_lpc.c",
    "celt/quant_bands.c",
    "celt/rate.c",
    "celt/vq.c",
    "silk/CNG.c",
    "silk/code_signs.c",
    "silk/init_decoder.c",
    "silk/decode_core.c",
    "silk/decode_frame.c",
    "silk/decode_parameters.c",
    "silk/decode_indices.c",
    "silk/decode_pulses.c",
    "silk/decoder_set_fs.c",
    "silk/dec_API.c",
    "silk/enc_API.c",
    "silk/encode_indices.c",
    "silk/encode_pulses.c",
    "silk/gain_quant.c",
    "silk/interpolate.c",
    "silk/LP_variable_cutoff.c",
    "silk/NLSF_decode.c",
    "silk/NSQ.c",
    "silk/NSQ_del_dec.c",
    "silk/PLC.c",
    "silk/shell_coder.c",
    "silk/tables_gain.c",
    "silk/tables_LTP.c",
    "silk/tables_NLSF_CB_NB_MB.c",
    "silk/tables_NLSF_CB_WB.c",
    "silk/tables_other.c",
    "silk/tables_pitch_lag.c",
    "silk/tables_pulses_per_block.c",
    "silk/VAD.c",
    "silk/control_audio_bandwidth.c",
    "silk/quant_LTP_gains.c",
    "silk/VQ_WMat_EC.c",
    "silk/HP_variable_cutoff.c",
    "silk/NLSF_encode.c",
    "silk/NLSF_VQ.c",
    "silk/NLSF_unpack.c",
    "silk/NLSF_del_dec_quant.c",
    "silk/process_NLSFs.c",
    "silk/stereo_LR_to_MS.c",
    "silk/stereo_MS_to_LR.c",
    "silk/check_control_input.c",
    "silk/control_SNR.c",
    "silk/init_encoder.c",
    "silk/control_codec.c",
    "silk/A2NLSF.c",
    "silk/ana_filt_bank_1.c",
    "silk/biquad_alt.c",
    "silk/bwexpander_32.c",
    "silk/bwexpander.c",
    "silk/debug.c",
    "silk/decode_pitch.c",
    "silk/inner_prod_aligned.c",
    "silk/lin2log.c",
    "silk/log2lin.c",
    "silk/LPC_analysis_filter.c",
    "silk/LPC_inv_pred_gain.c",
    "silk/table_LSF_cos.c",
    "silk/NLSF2A.c",
    "silk/NLSF_stabilize.c",
    "silk/NLSF_VQ_weights_laroia.c",
    "silk/pitch_est_tables.c",
    "silk/resampler.c",
    "silk/resampler_down2_3.c",
    "silk/resampler_down2.c",
    "silk/resampler_private_AR2.c",
    "silk/resampler_private_down_FIR.c",
    "silk/resampler_private_IIR_FIR.c",
    "silk/resampler_private_up2_HQ.c",
    "silk/resampler_rom.c",
    "silk/sigm_Q15.c",
    "silk/sort.c",
    "silk/sum_sqr_shift.c",
    "silk/stereo_decode_pred.c",
    "silk/stereo_encode_pred.c",
    "silk/stereo_find_predictor.c",
    "silk/stereo_quant_pred.c",
    "silk/LPC_fit.c",
    "silk/fixed/LTP_analysis_filter_FIX.c",
    "silk/fixed/LTP_scale_ctrl_FIX.c",
    "silk/fixed/corrMatrix_FIX.c",
    "silk/fixed/encode_frame_FIX.c",
    "silk/fixed/find_LPC_FIX.c",
    "silk/fixed/find_LTP_FIX.c",
    "silk/fixed/find_pitch_lags_FIX.c",
    "silk/fixed/find_pred_coefs_FIX.c",
    "silk/fixed/noise_shape_analysis_FIX.c",
    "silk/fixed/process_gains_FIX.c",
    "silk/fixed/regularize_correlations_FIX.c",
    "silk/fixed/residual_energy16_FIX.c",
    "silk/fixed/residual_energy_FIX.c",
    "silk/fixed/warped_autocorrelation_FIX.c",
    "silk/fixed/apply_sine_window_FIX.c",
    "silk/fixed/autocorr_FIX.c",
    "silk/fixed/burg_modified_FIX.c",
    "silk/fixed/k2a_FIX.c",
    "silk/fixed/k2a_Q16_FIX.c",
    "silk/fixed/pitch_analysis_core_FIX.c",
    "silk/fixed/vector_ops_FIX.c",
    "silk/fixed/schur64_FIX.c",
    "silk/fixed/schur_FIX.c",
};

pub const Config = struct {
    config_header: ?std.Build.LazyPath = null,
};

const ConfigHeaderValues = struct {
    FIXED_POINT: u8 = 1,
    OPUS_BUILD: u8 = 1,
    VAR_ARRAYS: u8 = 1,
    USE_ALLOCA: ?u8 = null,
    NONTHREADSAFE_PSEUDOSTACK: ?u8 = null,
    HAVE_LRINT: u8 = 1,
    HAVE_LRINTF: u8 = 1,
    DISABLE_FLOAT_API: u8 = 1,
    CUSTOM_MODES: ?u8 = null,
    ENABLE_HARDENING: ?u8 = null,
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = "https://github.com/xiph/opus.git",
        .commit = "2d862ea14b233e5a3f3afaf74d96050691af3cd5",
    });
    const config: Config = .{
        .config_header = b.option(
            std.Build.LazyPath,
            "opus_config_header",
            "Optional path to a complete Opus config header; otherwise embed-zig renders pkg/opus/config.h.in with Zig's config header support",
        ),
    };
    const config_header = createConfigHeader(b, config);
    const c_wrappers = createWrappedCSources(b, repo);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "opus",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addConfigHeader(config_header);
    for (include_dirs) |dir| {
        lib.root_module.addIncludePath(repo.includePath(dir));
    }
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    for (c_wrappers) |src| {
        lib.root_module.addCSourceFile(.{ .file = src });
    }
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/opus/src/binding.c") });
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/opus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addConfigHeader(config_header);
    for (include_dirs) |dir| {
        mod.addIncludePath(repo.includePath(dir));
    }
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("opus", mod) catch @panic("OOM");
    b.installArtifact(lib);
    library = lib;
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("opus requires embed");
    const mod = b.modules.get("opus") orelse @panic("opus module missing");
    const lib = library orelse @panic("opus library missing");
    mod.addImport("embed", embed);
    mod.linkLibrary(lib);
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const embed_std = b.modules.get("embed_std") orelse @panic("opus tests require embed_std");
    const testing = b.modules.get("testing") orelse @panic("opus tests require testing");
    compile.root_module.addImport("embed_std", embed_std);
    compile.root_module.addImport("testing", testing);
}

fn createConfigHeader(b: *std.Build, config: Config) *std.Build.Step.ConfigHeader {
    if (config.config_header) |header| {
        const write_files = b.addWriteFiles();
        const template = write_files.add("config.h.in",
            \\#ifndef EMBED_ZIG_OPUS_CONFIG_H
            \\#define EMBED_ZIG_OPUS_CONFIG_H
            \\#include "@OPUS_USER_CONFIG_HEADER@"
            \\#endif
            \\
        );
        return b.addConfigHeader(.{
            .style = .{ .autoconf_at = template },
            .include_path = "config.h",
        }, .{
            .OPUS_USER_CONFIG_HEADER = normalizeIncludePath(b, header),
        });
    }

    return b.addConfigHeader(.{
        .style = .{ .autoconf_undef = b.path("pkg/opus/config.h.in") },
        .include_path = "config.h",
    }, ConfigHeaderValues{});
}

fn createWrappedCSources(
    b: *std.Build,
    repo: GitRepo.GitRepo,
) []const std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    const c_wrappers = b.allocator.alloc(std.Build.LazyPath, c_sources.len) catch @panic("OOM");
    for (c_wrappers, c_sources) |*wrapper, src| {
        wrapper.* = write_files.add(wrapperName(b, src), b.fmt(
            \\#include "config.h"
            \\#include "{s}"
            \\
        , .{normalizeIncludePath(b, repo.sourcePath(src))}));
    }
    return c_wrappers;
}

fn normalizeIncludePath(b: *std.Build, header: std.Build.LazyPath) []const u8 {
    const raw = header.getPath(b);
    const resolved = if (std.fs.path.isAbsolute(raw))
        raw
    else
        b.pathFromRoot(raw);
    return std.mem.replaceOwned(u8, b.allocator, resolved, "\\", "/") catch @panic("OOM");
}

fn wrapperName(b: *std.Build, src: []const u8) []const u8 {
    const flattened = std.mem.replaceOwned(u8, b.allocator, src, "/", "__") catch @panic("OOM");
    return b.fmt("{s}.wrap.c", .{flattened});
}
