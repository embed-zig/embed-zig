const std = @import("std");

pub const PartitionType = enum {
    app,
    data,
};

pub const PartitionSubtype = union(enum) {
    factory,
    ota,
    ota_0,
    ota_1,
    phy,
    nvs,
    spiffs,
    littlefs,
    device_profile,
    custom_name: []const u8,
    custom_value: u8,
};

pub const NvsValueType = enum { u8, i8, u16, i16, u32, i32, u64, i64, string, blob };

pub const NvsValue = union(enum) {
    signed: i64,
    unsigned: u64,
    str: []const u8,
    blob: []const u8,
};

pub const NvsEntry = struct {
    namespace: []const u8,
    key: []const u8,
    value_type: NvsValueType,
    value: NvsValue,
};

pub const FsImage = struct {
    dir: []const u8,
};

pub const DataSource = union(enum) {
    nvs: NvsData,
    spiffs: FsImage,
    littlefs: FsImage,
    raw_file: []const u8,
};

pub const NvsData = struct {
    entries: []const NvsEntry,
};

pub const Partition = struct {
    name: []const u8,
    kind: PartitionType,
    subtype: PartitionSubtype,
    offset: ?u32 = null,
    size: u32,
    flags: ?[]const u8 = null,
    data: ?DataSource = null,
};

pub const Table = struct {
    offset: u32,
    entries: []const Partition,
};

pub const data = struct {
    pub fn nvs(comptime object: anytype) DataSource {
        return .{
            .nvs = .{
                .entries = comptime nvsEntriesFromObject(object),
            },
        };
    }

    pub fn spiffs(dir: []const u8) DataSource {
        return .{ .spiffs = .{ .dir = dir } };
    }

    pub fn littlefs(dir: []const u8) DataSource {
        return .{ .littlefs = .{ .dir = dir } };
    }

    pub fn rawFile(path: []const u8) DataSource {
        return .{ .raw_file = path };
    }
};

fn nvsEntriesFromObject(comptime object: anytype) []const NvsEntry {
    const Holder = struct {
        pub const entries = buildNvsEntries(object);
    };
    return Holder.entries[0..];
}

fn buildNvsEntries(comptime object: anytype) [countNvsEntries(object)]NvsEntry {
    const count = countNvsEntries(object);
    var entries: [count]NvsEntry = undefined;
    var index: usize = 0;

    const object_info = @typeInfo(@TypeOf(object));
    if (object_info != .@"struct") {
        @compileError("partition.data.nvs(...) expects a struct of namespaces");
    }

    inline for (object_info.@"struct".fields) |namespace_field| {
        const namespace_name = namespace_field.name;
        const namespace_value = @field(object, namespace_name);
        const namespace_info = @typeInfo(@TypeOf(namespace_value));
        if (namespace_info != .@"struct") {
            @compileError(std.fmt.comptimePrint(
                "NVS namespace '{s}' must be a struct of key/value pairs",
                .{namespace_name},
            ));
        }

        inline for (namespace_info.@"struct".fields) |entry_field| {
            const key = entry_field.name;
            const value = @field(namespace_value, key);
            const value_info = inferNvsValue(value);
            entries[index] = .{
                .namespace = namespace_name,
                .key = key,
                .value_type = value_info.value_type,
                .value = value_info.value,
            };
            index += 1;
        }
    }

    return entries;
}

fn countNvsEntries(comptime object: anytype) usize {
    const object_info = @typeInfo(@TypeOf(object));
    if (object_info != .@"struct") {
        @compileError("partition.data.nvs(...) expects a struct of namespaces");
    }

    var count: usize = 0;
    inline for (object_info.@"struct".fields) |namespace_field| {
        const namespace_value = @field(object, namespace_field.name);
        const namespace_info = @typeInfo(@TypeOf(namespace_value));
        if (namespace_info != .@"struct") {
            @compileError(std.fmt.comptimePrint(
                "NVS namespace '{s}' must be a struct of key/value pairs",
                .{namespace_field.name},
            ));
        }
        count += namespace_info.@"struct".fields.len;
    }
    return count;
}

fn inferNvsValue(comptime value: anytype) struct {
    value_type: NvsValueType,
    value: NvsValue,
} {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => .{
            .value_type = .u8,
            .value = .{ .unsigned = if (value) 1 else 0 },
        },
        .int => |info| .{
            .value_type = switch (info.bits) {
                0...8 => if (info.signedness == .signed) .i8 else .u8,
                9...16 => if (info.signedness == .signed) .i16 else .u16,
                17...32 => if (info.signedness == .signed) .i32 else .u32,
                else => if (info.signedness == .signed) .i64 else .u64,
            },
            .value = switch (info.signedness) {
                .signed => .{ .signed = @as(i64, value) },
                .unsigned => .{ .unsigned = @as(u64, value) },
            },
        },
        .comptime_int => .{
            .value_type = if (value < 0) .i64 else .u64,
            .value = if (value < 0)
                .{ .signed = value }
            else
                .{ .unsigned = value },
        },
        .pointer => |info| blk: {
            if (info.size == .slice and info.child == u8) {
                break :blk .{
                    .value_type = .string,
                    .value = .{ .str = value },
                };
            }
            if (info.size == .one and @typeInfo(info.child) == .array and @typeInfo(info.child).array.child == u8) {
                break :blk .{
                    .value_type = .string,
                    .value = .{ .str = std.mem.sliceTo(value, 0) },
                };
            }
            @compileError("unsupported pointer type in partition.data.nvs(...)");
        },
        .array => |info| {
            if (info.child != u8) @compileError("unsupported array type in partition.data.nvs(...)");
            return .{
                .value_type = .string,
                .value = .{ .str = value[0..] },
            };
        },
        else => @compileError("unsupported value type in partition.data.nvs(...)"),
    };
}
