const EnumLiteral = @Type(.enum_literal);

pub fn isUnique(
    comptime periphs: anytype,
    comptime len: usize,
    comptime label: EnumLiteral,
    comptime id: u32,
) bool {
    inline for (0..len) |i| {
        if (labelEql(periphs[i].label, label)) return false;
        if (periphs[i].id == id) return false;
    }
    return true;
}

pub fn isUniqueAcross(
    comptime registries: anytype,
    comptime label: EnumLiteral,
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
    comptime label: EnumLiteral,
    comptime id: u32,
    comptime duplicate_label_message: []const u8,
    comptime duplicate_id_message: []const u8,
) void {
    inline for (0..len) |i| {
        if (labelEql(periphs[i].label, label)) {
            @compileError(duplicate_label_message);
        }
        if (periphs[i].id == id) {
            @compileError(duplicate_id_message);
        }
    }
}

pub fn ensureUniqueAcross(
    comptime registries: anytype,
    comptime label: EnumLiteral,
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

fn labelEql(comptime a: EnumLiteral, comptime b: EnumLiteral) bool {
    const a_name = @tagName(a);
    const b_name = @tagName(b);
    if (a_name.len != b_name.len) return false;
    inline for (a_name, 0..) |ch, i| {
        if (ch != b_name[i]) return false;
    }
    return true;
}
