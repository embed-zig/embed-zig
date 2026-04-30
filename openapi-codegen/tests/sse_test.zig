const glib = @import("glib");
const lib = @import("std");
const codegen = @import("codegen");

const sse = codegen.sse.make(lib);
const ownership = @import("sse/ownership/test.zig");
const selection = @import("sse/selection/test.zig");
const gstd = @import("gstd");

test "sse" {
    var t = glib.testing.T.new(lib, gstd.runtime.time, .unit);
    defer t.deinit();

    t.run("sse/Reader", sse.ReaderTestRunner(lib));
    t.run("sse/Writer", sse.WriterTestRunner(lib));
    t.run("sse/ownership", ownership.TestRunner());
    t.run("sse/selection", selection.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
