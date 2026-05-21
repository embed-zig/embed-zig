const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const State = @import("State.zig");

pub fn reduce(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;
    var next = store.get();
    _ = reduceState(&next, message);
    store.set(next);
}

pub fn reduceState(state: *State, message: Message) bool {
    switch (message.body) {
        .display_set => |event| {
            const changed = state.enabled != event.enabled or state.brightness != event.brightness;
            state.enabled = event.enabled;
            state.brightness = event.brightness;
            return changed;
        },
        else => return false,
    }
}
