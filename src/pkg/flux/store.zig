//! Redux-style State Store
//!
//! Single-direction data flow for embedded UI:
//!   Event → dispatch() → reducer modifies State → dirty flag set
//!   render checks isDirty() → reads state/prev → draws framebuffer
//!   commitFrame() snapshots prev = state, clears dirty
//!
//! Thread safety: Store is designed for single-thread use.
//! External threads push events via a Channel, the UI thread
//! drains the channel and calls dispatch().

/// Create a typed Store for the given State and Event types.
///
/// `State` must support value copy (no pointers to self).
/// `Event` is typically a tagged union.
///
/// Example:
/// ```
/// const GameState = struct { score: u32 = 0 };
/// const GameEvent = union(enum) { score_up, reset };
///
/// fn reduce(s: *GameState, e: GameEvent) void {
///     switch (e) {
///         .score_up => s.score += 1,
///         .reset => s.* = .{},
///     }
/// }
///
/// var store = Store(GameState, GameEvent).init(.{}, reduce);
/// store.dispatch(.score_up);
/// ```
pub fn Store(comptime State: type, comptime Event: type) type {
    return struct {
        const Self = @This();

        state: State,
        prev: State,
        dirty: bool,
        reducer: *const fn (*State, Event) void,

        /// Create a store with initial state and reducer function.
        pub fn init(initial: State, reducer: *const fn (*State, Event) void) Self {
            return .{
                .state = initial,
                .prev = initial,
                .dirty = true, // first frame always needs render
                .reducer = reducer,
            };
        }

        /// Dispatch a single event — calls reducer, marks dirty.
        pub fn dispatch(self: *Self, event: Event) void {
            self.reducer(&self.state, event);
            self.dirty = true;
        }

        /// Dispatch multiple events in a batch — calls reducer for each,
        /// marks dirty once at the end.
        pub fn dispatchBatch(self: *Self, events: []const Event) void {
            for (events) |event| {
                self.reducer(&self.state, event);
            }
            if (events.len > 0) {
                self.dirty = true;
            }
        }

        /// Check if state changed since last commitFrame.
        pub fn isDirty(self: *const Self) bool {
            return self.dirty;
        }

        /// Get current state (read-only, for rendering).
        pub fn getState(self: *const Self) *const State {
            return &self.state;
        }

        /// Get previous frame state (read-only, for diff rendering).
        pub fn getPrev(self: *const Self) *const State {
            return &self.prev;
        }

        /// End frame — snapshot current state as prev, clear dirty.
        /// Call this after rendering is complete.
        pub fn commitFrame(self: *Self) void {
            self.prev = self.state;
            self.dirty = false;
        }
    };
}
