// Host tool that renders the staged IDF configuration files for one app build.
const std = @import("std");
const build_config = @import("build_config");
const esp_idf = @import("esp_idf");
const grt_build = @import("grt_build");

const SdkConfig = esp_idf.SdkConfig;
const PartitionTable = esp_idf.PartitionTable;

comptime {
    ensureDecl("chip");
    ensureDecl("partition_table");
    ensureDecl("sdk_config");
    ensureStringValue(@TypeOf(build_config.chip), "build_config.chip");
    if (@TypeOf(build_config.partition_table) != PartitionTable) {
        @compileError("build_config.partition_table must be esp_idf.PartitionTable");
    }
    SdkConfig.validateMacroSet(@TypeOf(build_config.sdk_config), "build_config.sdk_config");
    SdkConfig.validateMacroSet(@TypeOf(grt_build.sdk_config), "grt.build.sdk_config");
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_allocator = temp_arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print(
            "usage: sdkconfig_generator <sdkconfig-output-path> <partition-csv-output-path> <partition-filename-for-idf> [build-config-stamp]\n",
            .{},
        );
        return error.InvalidArguments;
    }

    const sdkconfig_output_path = args[1];
    const partition_output_path = args[2];
    const partition_filename_for_idf = args[3];

    const rendered = try renderSdkConfig(allocator, temp_allocator, partition_filename_for_idf);
    defer allocator.free(rendered);
    try writeFileCreatingParent(sdkconfig_output_path, rendered);

    const sdkconfig_preconfigure_path = try preconfigureSnapshotPath(allocator, sdkconfig_output_path);
    defer allocator.free(sdkconfig_preconfigure_path);
    try writeFileCreatingParent(sdkconfig_preconfigure_path, rendered);

    const partitions_csv = try renderPartitionCsv(allocator);
    defer allocator.free(partitions_csv);
    try writeFileCreatingParent(partition_output_path, partitions_csv);
}

fn renderSdkConfig(
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    partition_filename_for_idf: []const u8,
) ![]u8 {
    var docs = std.ArrayList(SdkConfig.ModuleDoc).empty;
    defer docs.deinit(temp_allocator);

    try docs.append(temp_allocator, try generatedConfigDoc(temp_allocator, partition_filename_for_idf));
    try docs.append(temp_allocator, try macroConfigDoc(
        temp_allocator,
        "build_config",
        build_config.sdk_config,
        grt_build.sdk_config,
    ));

    return SdkConfig.render(allocator, docs.items);
}

fn generatedConfigDoc(allocator: std.mem.Allocator, partition_filename_for_idf: []const u8) !SdkConfig.ModuleDoc {
    const chip_upper = try upperChipName(allocator, build_config.chip);
    errdefer allocator.free(chip_upper);

    const target_flag = try std.fmt.allocPrint(allocator, "CONFIG_IDF_TARGET_{s}", .{chip_upper});
    errdefer allocator.free(target_flag);

    const partition_offset = try std.fmt.allocPrint(allocator, "0x{x}", .{build_config.partition_table.offset});
    errdefer allocator.free(partition_offset);

    const entries = try allocator.alloc(SdkConfig.Entry, 7);
    entries[0] = SdkConfig.Entry.str("CONFIG_IDF_TARGET", build_config.chip);
    entries[1] = SdkConfig.Entry.flag(target_flag, true);
    entries[2] = SdkConfig.Entry.flag("CONFIG_PARTITION_TABLE_CUSTOM", true);
    entries[3] = SdkConfig.Entry.str("CONFIG_PARTITION_TABLE_CUSTOM_FILENAME", partition_filename_for_idf);
    entries[4] = SdkConfig.Entry.str("CONFIG_PARTITION_TABLE_FILENAME", partition_filename_for_idf);
    entries[5] = SdkConfig.Entry.raw("CONFIG_PARTITION_TABLE_OFFSET", partition_offset);
    entries[6] = SdkConfig.Entry.flag("CONFIG_PARTITION_TABLE_MD5", true);

    return .{
        .name = "generated",
        .entries = entries,
    };
}

fn macroConfigDoc(
    allocator: std.mem.Allocator,
    name: []const u8,
    comptime user_config: anytype,
    comptime grt_config: anytype,
) !SdkConfig.ModuleDoc {
    const User = @TypeOf(user_config);
    const Grt = @TypeOf(grt_config);
    const entries = try allocator.alloc(SdkConfig.Entry, comptime userOnlyCount(User, Grt) + @typeInfo(Grt).@"struct".fields.len);

    var idx: usize = 0;
    inline for (@typeInfo(User).@"struct".fields) |field| {
        if (comptime @hasField(Grt, field.name)) continue;
        entries[idx] = try entryFromField(allocator, field.name, @field(user_config, field.name));
        idx += 1;
    }
    inline for (@typeInfo(Grt).@"struct".fields) |field| {
        entries[idx] = try entryFromField(allocator, field.name, @field(grt_config, field.name));
        idx += 1;
    }

    return .{
        .name = name,
        .entries = entries,
    };
}

fn entryFromField(allocator: std.mem.Allocator, comptime field_name: []const u8, value: anytype) !SdkConfig.Entry {
    const key = try std.fmt.allocPrint(allocator, "CONFIG_{s}", .{field_name});
    errdefer allocator.free(key);

    const Value = @TypeOf(value);
    if (Value == SdkConfig.RawValue) {
        return SdkConfig.Entry.raw(key, value.text);
    }

    return switch (@typeInfo(Value)) {
        .bool => SdkConfig.Entry.flag(key, value),
        .int, .comptime_int => SdkConfig.Entry.int(key, @intCast(value)),
        .@"enum" => SdkConfig.Entry.raw(key, @tagName(value)),
        .enum_literal => SdkConfig.Entry.raw(key, @tagName(value)),
        .pointer, .array => SdkConfig.Entry.str(key, stringValue(value)),
        else => unreachable,
    };
}

fn renderPartitionCsv(allocator: std.mem.Allocator) ![]u8 {
    const table = build_config.partition_table;
    PartitionTable.validateEntries(table.entries) catch {
        @panic("partition table must include a valid app partition and use matching app/data subtypes");
    };
    const resolved = try PartitionTable.resolveEntriesAlloc(allocator, table);
    defer allocator.free(resolved);
    return PartitionTable.renderCsv(allocator, resolved);
}

fn writeFileCreatingParent(path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
    });
}

fn preconfigureSnapshotPath(allocator: std.mem.Allocator, sdkconfig_output_path: []const u8) ![]u8 {
    if (std.fs.path.dirname(sdkconfig_output_path)) |dir_name| {
        return try std.fs.path.join(allocator, &.{ dir_name, "sdkconfig.preconfigure.generated" });
    }
    return allocator.dupe(u8, "sdkconfig.preconfigure.generated");
}

fn upperChipName(allocator: std.mem.Allocator, chip: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, chip.len);
    for (chip, out) |src, *dst| {
        dst.* = std.ascii.toUpper(src);
    }
    return out;
}

fn stringValue(value: anytype) []const u8 {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => value,
            .one => value[0..],
            else => unreachable,
        },
        .array => value[0..],
        else => unreachable,
    };
}

fn userOnlyCount(comptime User: type, comptime Grt: type) usize {
    var count: usize = 0;
    inline for (@typeInfo(User).@"struct".fields) |field| {
        if (!@hasField(Grt, field.name)) count += 1;
    }
    return count;
}

fn ensureDecl(comptime name: []const u8) void {
    if (!@hasDecl(build_config, name)) {
        @compileError(std.fmt.comptimePrint("build_config must define `pub const {s}`", .{name}));
    }
}

fn ensureStringValue(comptime Value: type, comptime name: []const u8) void {
    switch (@typeInfo(Value)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return;
            if (ptr.size == .one) {
                switch (@typeInfo(ptr.child)) {
                    .array => |array| if (array.child == u8) return,
                    else => {},
                }
            }
        },
        .array => |array| if (array.child == u8) return,
        else => {},
    }
    @compileError(std.fmt.comptimePrint("{s} must be a string literal or []const u8", .{name}));
}
