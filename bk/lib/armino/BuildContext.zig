const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

chip: []const u8,
make_target: []const u8,
ap_target: []const u8,
cp_target: []const u8,
zig_target: std.Build.ResolvedTarget,
armino_path: []const u8,
toolchain_path: []const u8,
toolchain_dir: []const u8,
toolchain_archive_path: []const u8,
toolchain_url: []const u8,
mklittlefs_path: []const u8,
mklittlefs_archive_path: []const u8,
mklittlefs_url: []const u8,
build_dir: []const u8,
armino_build_dir: []const u8,
app_root: []const u8,
loader_path: []const u8,
port: ?[]const u8,
flash_baud: u32,
reset_baud: u32,
reset_type: u32,
python_venv_dir: []const u8,
python_path_dir: []const u8,
logs_dir: []const u8,

pub fn resolve(b: *std.Build, opts: anytype) Self {
    const build_config = opts.build_config;
    const chip = build_config.chip;
    const build_dir = b.option([]const u8, "build", "Generated BK build directory") orelse optionOrDefault(opts, "build_dir", ".build");
    const armino_path = b.option([]const u8, "armino-sdk-path", "Armino SDK root directory; defaults to ARMINO_SDK_PATH") orelse
        getEnvOrNull(b, "ARMINO_SDK_PATH") orelse "";
    const app_root = optionOrDefault(opts, "app_root", b.pathFromRoot(""));
    const loader_path = b.option([]const u8, "bk-loader-path", "bk_loader executable path; defaults to BK_LOADER_PATH") orelse
        getEnvOrNull(b, "BK_LOADER_PATH") orelse
        "";
    const toolchain_dir = b.pathFromRoot(b.pathJoin(&.{ build_dir, "toolchains", "gcc-arm-none-eabi-10.3-2021.10" }));
    const toolchain_path = b.pathJoin(&.{ toolchain_dir, "bin" });
    const toolchain_archive_name = toolchainArchiveName();
    const toolchain_archive_path = b.pathFromRoot(b.pathJoin(&.{ build_dir, "downloads", toolchain_archive_name }));
    const mklittlefs_archive_name = mklittlefsArchiveName();
    const mklittlefs_path = b.pathFromRoot(b.pathJoin(&.{ build_dir, "tools", "mklittlefs-3.1.0", "mklittlefs", "mklittlefs" }));
    const mklittlefs_archive_path = b.pathFromRoot(b.pathJoin(&.{ build_dir, "downloads", mklittlefs_archive_name }));
    const python_venv_dir = b.pathFromRoot(b.pathJoin(&.{ build_dir, "python-venv" }));
    const python_path_dir = b.pathJoin(&.{ python_venv_dir, "bin" });

    if (armino_path.len == 0) {
        std.debug.panic("missing Armino SDK root; pass -Darmino-sdk-path=<path> or set ARMINO_SDK_PATH", .{});
    }

    const make_target = chip;
    const cp_target = chip;
    const ap_target = b.fmt("{s}_ap", .{chip});
    const zig_target = resolveZigTarget(b, chip);

    validateSdkTarget(b, armino_path, cp_target, ap_target);

    const armino_build_dir = b.pathFromRoot(b.pathJoin(&.{ build_dir, "armino_build" }));

    return .{
        .chip = b.dupe(chip),
        .make_target = b.dupe(make_target),
        .ap_target = b.dupe(ap_target),
        .cp_target = b.dupe(cp_target),
        .zig_target = zig_target,
        .armino_path = b.dupe(armino_path),
        .toolchain_path = b.dupe(toolchain_path),
        .toolchain_dir = b.dupe(toolchain_dir),
        .toolchain_archive_path = b.dupe(toolchain_archive_path),
        .toolchain_url = toolchainUrl(),
        .mklittlefs_path = b.dupe(mklittlefs_path),
        .mklittlefs_archive_path = b.dupe(mklittlefs_archive_path),
        .mklittlefs_url = mklittlefsUrl(),
        .build_dir = b.dupe(build_dir),
        .armino_build_dir = armino_build_dir,
        .app_root = b.dupe(app_root),
        .loader_path = b.dupe(loader_path),
        .port = b.option([]const u8, "port", "Serial port used by flash/monitor"),
        .flash_baud = b.option(u32, "flash-baud", "BK loader download baudrate") orelse 2_000_000,
        .reset_baud = b.option(u32, "reset-baud", "BK loader reset baudrate") orelse 115_200,
        .reset_type = b.option(u32, "reset-type", "BK loader reset type") orelse 0,
        .python_venv_dir = python_venv_dir,
        .python_path_dir = b.dupe(python_path_dir),
        .logs_dir = b.pathFromRoot(b.pathJoin(&.{ build_dir, "logs" })),
    };
}

pub fn firmwareBin(context: Self, b: *std.Build, app_name: []const u8) []const u8 {
    return b.pathJoin(&.{ context.armino_build_dir, context.make_target, app_name, "package", "all-app.bin" });
}

fn resolveZigTarget(b: *std.Build, chip: []const u8) std.Build.ResolvedTarget {
    if (std.mem.eql(u8, chip, "bk7258")) {
        return b.resolveTargetQuery(.{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
            .os_tag = .freestanding,
            .abi = .eabihf,
        });
    }
    if (std.mem.eql(u8, chip, "bk7259")) {
        std.debug.panic("bk7259 Zig target is not enabled yet; add cortex-m52 soft-float support after validating Zig CPU support", .{});
    }
    std.debug.panic("unsupported BK chip '{s}'", .{chip});
}

fn validateSdkTarget(b: *std.Build, armino_path: []const u8, cp_target: []const u8, ap_target: []const u8) void {
    const cp_soc_config = b.pathJoin(&.{ armino_path, "cp", "middleware", "soc", cp_target, "soc_config.mk" });
    const ap_soc_config = b.pathJoin(&.{ armino_path, "ap", "middleware", "soc", ap_target, "soc_config.mk" });
    std.fs.cwd().access(cp_soc_config, .{}) catch {
        std.debug.panic("Armino SDK at '{s}' does not support CP target '{s}'", .{ armino_path, cp_target });
    };
    std.fs.cwd().access(ap_soc_config, .{}) catch {
        std.debug.panic("Armino SDK at '{s}' does not support AP target '{s}'", .{ armino_path, ap_target });
    };
}

fn toolchainArchiveName() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "gcc-arm-none-eabi-10.3-2021.10-mac.tar.bz2",
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2",
            .aarch64 => "gcc-arm-none-eabi-10.3-2021.10-aarch64-linux.tar.bz2",
            else => std.debug.panic("unsupported BK Arm GCC host architecture '{s}' on Linux", .{@tagName(builtin.target.cpu.arch)}),
        },
        else => std.debug.panic("unsupported BK Arm GCC host OS '{s}'", .{@tagName(builtin.target.os.tag)}),
    };
}

fn toolchainUrl() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "https://developer.arm.com/-/media/Files/downloads/gnu-rm/10.3-2021.10/gcc-arm-none-eabi-10.3-2021.10-mac.tar.bz2",
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "https://developer.arm.com/-/media/Files/downloads/gnu-rm/10.3-2021.10/gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2",
            .aarch64 => "https://developer.arm.com/-/media/Files/downloads/gnu-rm/10.3-2021.10/gcc-arm-none-eabi-10.3-2021.10-aarch64-linux.tar.bz2",
            else => unreachable,
        },
        else => unreachable,
    };
}

fn mklittlefsArchiveName() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "x86_64-apple-darwin14-mklittlefs-4aca452.tar.gz",
        .linux => switch (builtin.target.cpu.arch) {
            .aarch64 => "aarch64-linux-gnu-mklittlefs-4aca452.tar.gz",
            .x86_64 => "x86_64-linux-gnu-mklittlefs-4aca452.tar.gz",
            .arm => "arm-linux-gnueabihf-mklittlefs-4aca452.tar.gz",
            else => std.debug.panic("unsupported mklittlefs host architecture '{s}' on Linux", .{@tagName(builtin.target.cpu.arch)}),
        },
        else => std.debug.panic("unsupported mklittlefs host OS '{s}'", .{@tagName(builtin.target.os.tag)}),
    };
}

fn mklittlefsUrl() []const u8 {
    const base = "https://github.com/earlephilhower/mklittlefs/releases/download/3.1.0/";
    return switch (builtin.target.os.tag) {
        .macos => base ++ "x86_64-apple-darwin14-mklittlefs-4aca452.tar.gz",
        .linux => switch (builtin.target.cpu.arch) {
            .aarch64 => base ++ "aarch64-linux-gnu-mklittlefs-4aca452.tar.gz",
            .x86_64 => base ++ "x86_64-linux-gnu-mklittlefs-4aca452.tar.gz",
            .arm => base ++ "arm-linux-gnueabihf-mklittlefs-4aca452.tar.gz",
            else => unreachable,
        },
        else => unreachable,
    };
}

fn getEnvOrNull(b: *std.Build, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(b.allocator, name) catch null;
}

fn optionOrDefault(opts: anytype, comptime field_name: []const u8, default: []const u8) []const u8 {
    if (@hasField(@TypeOf(opts), field_name)) return @field(opts, field_name);
    return default;
}
