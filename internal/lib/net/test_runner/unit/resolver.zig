const testing_api = @import("testing");
const Resolver = @import("../../Resolver.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return Resolver.TestRunner(lib);
}
