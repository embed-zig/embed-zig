const glib = @import("glib");
const lib = @import("std");

const download = @import("stream/download/test.zig");
const upload = @import("stream/upload/test.zig");
const bidir = @import("stream/bidir/test.zig");
const runtime = @import("runtime");

test "stream" {
    var t = glib.testing.T.new(lib, runtime.time, .examples);
    defer t.deinit();

    t.run("stream/download", download.TestRunner());
    t.run("stream/upload", upload.TestRunner());
    t.run("stream/bidir", bidir.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
