const glib = @import("glib");

pub const ParsedLine = struct {
    name: []const u8,
    args: []const u8,
};

pub fn parseLine(line: []const u8) ?ParsedLine {
    const trimmed = glib.std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    var index: usize = 0;
    while (index < trimmed.len and !isSpace(trimmed[index])) : (index += 1) {}

    const name = trimmed[0..index];
    const args = glib.std.mem.trimLeft(u8, trimmed[index..], " \t");
    return .{
        .name = name,
        .args = args,
    };
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}
