const testing = embed.testing;
const embed = @import("embed");
const lib = @import("embed_std").std;

const download = @import("stream/download/test.zig");
const upload = @import("stream/upload/test.zig");
const bidir = @import("stream/bidir/test.zig");

test "stream" {
    var t = testing.T.new(lib, .examples);
    defer t.deinit();

    t.run("stream/download", download.TestRunner());
    t.run("stream/upload", upload.TestRunner());
    t.run("stream/bidir", bidir.TestRunner());
    if (!t.wait()) return error.TestFailed;
}
