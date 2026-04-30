pub const meta = .{
    .source_file = sourceFile(),
    .module = "openapi-codegen",
    .filter = "openapi-codegen/integration/stream",
    .label = .integration,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const lib = @import("std");

const download = @import("stream/download/test.zig");
const upload = @import("stream/upload/test.zig");
const bidir = @import("stream/bidir/test.zig");
const gstd = @import("gstd");

test "openapi-codegen/integration/stream" {
    var t = glib.testing.T.new(lib, gstd.runtime.time, .examples);
    defer t.deinit();

    t.run("stream/download", download.TestRunner());
    t.run("stream/upload", upload.TestRunner());
    t.run("stream/bidir", bidir.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
