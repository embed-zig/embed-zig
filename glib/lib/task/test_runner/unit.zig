const Builder = @import("../Builder.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return Builder.TestRunner(lib);
}
