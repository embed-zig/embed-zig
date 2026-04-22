const StoreObject = @import("store/Object.zig");
const StoreReducer = @import("store/Reducer.zig");
const StoreState = @import("store/State.zig");
const StoreStores = @import("store/Stores.zig");
const StoreSubscriber = @import("store/Subscriber.zig");
const StoreBuilder = @import("store/Builder.zig");

pub const Builder = StoreBuilder.Builder;
pub const BuilderOptions = StoreBuilder.BuilderOptions;
pub const default_max_stores = StoreBuilder.default_max_stores;
pub const default_max_state_nodes = StoreBuilder.default_max_state_nodes;
pub const default_max_store_refs = StoreBuilder.default_max_store_refs;
pub const default_max_depth = StoreBuilder.default_max_depth;

pub const Subscriber = StoreSubscriber;
pub const Object = StoreObject;
pub const Stores = StoreStores;
pub const State = StoreState;
pub const Reducer = StoreReducer;
pub const ReducerFn = StoreReducer;
