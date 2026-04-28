const context_mod = @import("context");

pub fn make(comptime std: type, comptime time: type) type {
    return context_mod.make(std, time);
}
