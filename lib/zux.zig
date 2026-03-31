pub const store = struct {
    pub const Subscriber = @import("zux/store/Subscriber.zig");
    pub const Object = @import("zux/store/Object.zig");
    pub const Stores = @import("zux/store/Stores.zig");
    pub const State = @import("zux/store/State.zig");
};

pub const event = @import("zux/event.zig");
pub const Subscriber = store.Subscriber;
pub const StoreObject = store.Object;
pub const Store = @import("zux/Store.zig");

test {
    _ = @import("zux/event.zig");
}
