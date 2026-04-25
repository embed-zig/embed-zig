const testing_mod = @import("testing");

pub fn make(comptime lib: type) @TypeOf(testing_mod.test_runner.unit.make(lib)) {
    return testing_mod.test_runner.unit.make(lib);
}
