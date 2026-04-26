const Assembler = @import("zux/Assembler.zig");
const Config = @import("zux/assembler/Config.zig");

pub const Store = @import("zux/Store.zig");
pub const ReducerFnType = Store.Reducer.ReducerFnType;
pub const pipeline = struct {
    pub const Message = @import("zux/pipeline/Message.zig");
};

pub const events = struct {
    pub const button = @import("zux/component/button/state.zig");
};

pub const spec = struct {
    pub const Component = @import("zux/spec/Component.zig");
    pub const UserStory = @import("zux/spec/UserStory.zig");
};

pub fn assemble(
    comptime grt: type,
    comptime config: Config,
) type {
    return Assembler.make(grt, config);
}

pub const test_runner = struct {
    pub const unit = @import("zux/test_runner/unit.zig");
    pub const integration = @import("zux/test_runner/integration.zig");
};
