const glib = @import("glib");
const lib = @import("std");

const petstore = @import("examples/petstore/test.zig");
const sse = @import("sse/roundtrip/test.zig");
const gstd = @import("gstd");

test "examples" {
    var t = glib.testing.T.new(lib, gstd.runtime.time, .examples);
    defer t.deinit();

    t.run("petstore", petstore.TestRunner());
    t.run("sse", sse.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
