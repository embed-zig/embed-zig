pub fn make(comptime lib: type) @import("testing").TestRunner {
    return @import("../../LineReader.zig").TestRunner(lib);
}
