const testing_mod = @import("testing");

pub fn make(comptime std: type, comptime time: type) @TypeOf(testing_mod.test_runner.unit.make(std, time)) {
    return testing_mod.test_runner.unit.make(std, time);
}
