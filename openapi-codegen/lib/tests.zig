const glib = @import("glib");
const openapi = @import("openapi");

const std = glib.std;

test "Files parses relative schema refs from current file directory" {
    comptime {
        const same_file = openapi.Files.parseSchemaRef("./apis/root.json", "#/components/schemas/Local") orelse
            return error.ExpectedSchemaRef;
        try expectString("./apis/root.json", same_file.file_name);
        try expectString("Local", same_file.schema_name);

        const sibling = openapi.Files.parseSchemaRef("./apis/root.json", "./schemas/common.json#/components/schemas/Pet") orelse
            return error.ExpectedSchemaRef;
        try expectString("./apis/schemas/common.json", sibling.file_name);
        try expectString("Pet", sibling.schema_name);

        const parent = openapi.Files.parseSchemaRef("./apis/v1/root.json", "../schemas/common.json#/components/schemas/Pet~1Dog") orelse
            return error.ExpectedSchemaRef;
        try expectString("./apis/schemas/common.json", parent.file_name);
        try expectString("Pet/Dog", parent.schema_name);
    }
}

test "comptime parser preserves schema enum literal values" {
    comptime {
        const spec = openapi.json.parse(
            \\{
            \\  "openapi": "3.1.0",
            \\  "info": { "title": "Enum Smoke", "version": "1.0.0" },
            \\  "paths": {},
            \\  "components": {
            \\    "schemas": {
            \\      "Mixed": {
            \\        "type": "object",
            \\        "enum": [
            \\          "ready",
            \\          true,
            \\          null,
            \\          -7,
            \\          1.5,
            \\          ["nested"],
            \\          { "code": 42 }
            \\        ]
            \\      }
            \\    }
            \\  }
            \\}
        );

        const schema_or_ref = spec.findSchema("Mixed") orelse return error.ExpectedSchema;
        const schema = switch (schema_or_ref) {
            .schema => |value| value,
            .reference => return error.ExpectedSchema,
        };

        try expectEqualUsize(7, schema.enum_values.len);
        try expectString("ready", schema.enum_values[0].string);
        try expectBool(true, schema.enum_values[1].bool);
        switch (schema.enum_values[2]) {
            .null => {},
            else => return error.ExpectedNullLiteral,
        }
        try expectEqualI64(-7, schema.enum_values[3].integer);
        try expectFloat(1.5, schema.enum_values[4].float);
        try expectString("nested", schema.enum_values[5].array[0].string);
        try expectString("code", schema.enum_values[6].object[0].name);
        try expectEqualI64(42, schema.enum_values[6].object[0].value.integer);
    }
}

fn expectString(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedString;
}

fn expectBool(expected: bool, actual: bool) !void {
    if (expected != actual) return error.UnexpectedBool;
}

fn expectEqualUsize(expected: usize, actual: usize) !void {
    if (expected != actual) return error.UnexpectedUsize;
}

fn expectEqualI64(expected: i64, actual: i64) !void {
    if (expected != actual) return error.UnexpectedI64;
}

fn expectFloat(expected: f64, actual: f64) !void {
    if (expected != actual) return error.UnexpectedFloat;
}
