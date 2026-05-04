const std = @import("std");

pub const ChipTarget = struct {
    name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    cpu_model: std.Target.Query.CpuModel,
    supported: bool,
};

pub const chip_targets = [_]ChipTarget{
    .{ .name = "esp32", .cpu_arch = .xtensa, .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32 }, .supported = false },
    .{ .name = "esp32s2", .cpu_arch = .xtensa, .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s2 }, .supported = false },
    .{ .name = "esp32s3", .cpu_arch = .xtensa, .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 }, .supported = true },
    .{ .name = "esp32c3", .cpu_arch = .riscv32, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 }, .supported = false },
    .{ .name = "esp32c6", .cpu_arch = .riscv32, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 }, .supported = false },
    .{ .name = "esp32h2", .cpu_arch = .riscv32, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 }, .supported = false },
    .{ .name = "esp32p4", .cpu_arch = .riscv32, .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 }, .supported = false },
};

pub fn resolveChipTarget(b: *std.Build, chip: []const u8) std.Build.ResolvedTarget {
    for (chip_targets) |entry| {
        if (std.mem.eql(u8, chip, entry.name)) {
            if (!entry.supported) {
                std.debug.panic("chip '{s}' is known but not yet supported", .{chip});
            }
            return b.resolveTargetQuery(.{
                .cpu_arch = entry.cpu_arch,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = entry.cpu_model,
            });
        }
    }
    std.debug.panic("unknown chip: '{s}'", .{chip});
}

pub const ToolchainSysroot = struct {
    root: []const u8,
    include_dir: std.Build.LazyPath,
};

pub fn resolveToolchainSysroot(
    b: *std.Build,
    chip: []const u8,
    env_map: *const std.process.EnvMap,
) ?ToolchainSysroot {
    const compiler = toolchainCompiler(chip) orelse return null;
    const root = runCompilerQuery(b, compiler, "-print-sysroot", env_map) orelse return null;
    return .{
        .root = root,
        .include_dir = .{ .cwd_relative = b.pathJoin(&.{ root, "include" }) },
    };
}

fn toolchainCompiler(chip: []const u8) ?[]const u8 {
    for (chip_targets) |entry| {
        if (std.mem.eql(u8, chip, entry.name)) {
            return switch (entry.cpu_arch) {
                .xtensa => "xtensa-esp-elf-gcc",
                .riscv32 => "riscv32-esp-elf-gcc",
                else => null,
            };
        }
    }
    return null;
}

fn runCompilerQuery(
    b: *std.Build,
    compiler: []const u8,
    arg: []const u8,
    env_map: *const std.process.EnvMap,
) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ compiler, arg },
        .env_map = env_map,
        .max_output_bytes = 8 * 1024,
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}
