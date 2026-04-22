pub fn isUnique(
    comptime periphs: anytype,
    comptime len: usize,
    comptime label: anytype,
    comptime id: u32,
) bool {
    const label_name = labelText(label);
    inline for (0..len) |i| {
        if (labelEql(periphs[i].label, label_name)) return false;
        if (periphs[i].id == id) return false;
    }
    return true;
}

pub fn isUniqueAcross(
    comptime registries: anytype,
    comptime label: anytype,
    comptime id: u32,
) bool {
    inline for (registries) |registry| {
        if (!isUnique(registry.periphs, registry.len, label, id)) return false;
    }
    return true;
}

pub fn ensureUnique(
    comptime periphs: anytype,
    comptime len: usize,
    comptime label: anytype,
    comptime id: u32,
    comptime duplicate_label_message: []const u8,
    comptime duplicate_id_message: []const u8,
) void {
    const label_name = labelText(label);
    inline for (0..len) |i| {
        if (labelEql(periphs[i].label, label_name)) {
            @compileError(duplicate_label_message);
        }
        if (periphs[i].id == id) {
            @compileError(duplicate_id_message);
        }
    }
}

pub fn ensureUniqueAcross(
    comptime registries: anytype,
    comptime label: anytype,
    comptime id: u32,
    comptime duplicate_label_message: []const u8,
    comptime duplicate_id_message: []const u8,
) void {
    inline for (registries) |registry| {
        ensureUnique(
            registry.periphs,
            registry.len,
            label,
            id,
            duplicate_label_message,
            duplicate_id_message,
        );
    }
}

pub fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.assembler.registry label must be enum_literal or []const u8"),
            },
            else => @compileError("zux.assembler.registry label must be enum_literal or []const u8"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.assembler.registry label must be enum_literal or []const u8"),
    };
}

fn labelEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}
