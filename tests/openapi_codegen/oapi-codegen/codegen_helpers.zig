const openapi = @import("openapi");
const codegen = @import("codegen");

pub fn makeFiles(comptime entries: anytype) openapi.Files {
    const info = @typeInfo(@TypeOf(entries));
    const len = switch (info) {
        .@"struct" => |struct_info| struct_info.fields.len,
        .array => |array_info| array_info.len,
        else => @compileError("makeFiles expects an array or tuple of file entries."),
    };

    comptime var items: [len]openapi.Files.Entry = undefined;
    inline for (entries, 0..) |entry, index| {
        items[index] = .{
            .name = entry.name,
            .spec = openapi.json.parse(entry.document),
        };
    }

    const Holder = struct {
        const stored = items;
    };

    return .{ .items = &Holder.stored };
}

pub fn assertModelsCompile(comptime std: type, comptime files: openapi.Files) void {
    _ = codegen.models.make(std, files);
}

pub fn assertClientCompile(comptime grt: type, comptime files: openapi.Files) void {
    _ = codegen.client.make(grt, files);
}

pub fn assertServerCompile(comptime grt: type, comptime files: openapi.Files) void {
    _ = codegen.server.make(grt, files);
}

pub fn assertClientServerCompile(comptime grt: type, comptime files: openapi.Files) void {
    assertModelsCompile(grt.std, files);
    assertClientCompile(grt, files);
    assertServerCompile(grt, files);
}
