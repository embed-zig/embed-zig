const testing = embed.testing;
const embed = @import("embed");
const lib = @import("embed_std").std;
const codegen = @import("codegen");

const sse = codegen.sse.make(lib);
const ownership = @import("sse/ownership/test.zig");
const selection = @import("sse/selection/test.zig");

test "sse" {
    var t = testing.T.new(lib, .unit);
    defer t.deinit();

    t.run("sse/Reader", sse.ReaderTestRunner(lib, testing));
    t.run("sse/Writer", sse.WriterTestRunner(lib, testing));
    t.run("sse/ownership", ownership.TestRunner());
    t.run("sse/selection", selection.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
