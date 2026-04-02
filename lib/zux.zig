pub const store = struct {
    pub const Subscriber = @import("zux/store/Subscriber.zig");
    pub const Object = @import("zux/store/Object.zig");
    pub const Stores = @import("zux/store/Stores.zig");
    pub const State = @import("zux/store/State.zig");
    pub const Reducer = @import("zux/store/Reducer.zig");
};

pub const button = @import("zux/button.zig");
pub const imu = @import("zux/imu.zig");
pub const nfc = @import("zux/Nfc.zig");
pub const wifi = @import("zux/Wifi.zig");
pub const bt = @import("zux/Bt.zig");
pub const ble = bt;
pub const netstack = @import("zux/NetStack.zig");
pub const event = @import("zux/event.zig");
pub const pipeline = struct {
    pub const Message = @import("zux/pipeline/Message.zig");
    pub const Emitter = @import("zux/pipeline/Emitter.zig");
    pub const Node = @import("zux/pipeline/Node.zig");
    pub const NodeBuilder = @import("zux/pipeline/NodeBuilder.zig");
    pub const BranchNode = @import("zux/pipeline/BranchNode.zig");
    pub const Pipeline = @import("zux/pipeline/Pipeline.zig");
};
pub const Subscriber = store.Subscriber;
pub const StoreObject = store.Object;
pub const Store = @import("zux/Store.zig");

test {
    _ = @import("zux/imu.zig");
    _ = @import("zux/Nfc.zig");
    _ = @import("zux/Wifi.zig");
    _ = @import("zux/Bt.zig");
    _ = @import("zux/NetStack.zig");
    _ = @import("zux/event.zig");
    _ = @import("zux/pipeline/Message.zig");
    _ = @import("zux/pipeline/Emitter.zig");
    _ = @import("zux/pipeline/Node.zig");
    _ = @import("zux/pipeline/NodeBuilder.zig");
    _ = @import("zux/pipeline/BranchNode.zig");
    _ = @import("zux/pipeline/Pipeline.zig");
    _ = @import("zux/store/Reducer.zig");
}
