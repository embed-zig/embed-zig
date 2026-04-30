const testing = embed.testing;
const embed = @import("embed");
const lib = @import("embed_std").std;

const petstore = @import("examples/petstore/test.zig");
const sse = @import("sse/roundtrip/test.zig");

test "examples" {
    var t = testing.T.new(lib, .examples);
    defer t.deinit();

    t.run("petstore", petstore.TestRunner());
    t.run("sse", sse.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
