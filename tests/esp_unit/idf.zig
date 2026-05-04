pub const meta = .{
    .source_file = sourceFile(),
    .module = "esp/idf",
    .filter = "esp/idf/unit",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const esp = @import("esp");

test "esp/idf/unit" {
    _ = esp.idf;
}
