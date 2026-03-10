//! AppRuntime — Unified event → state orchestrator.
//!
//! Combines event.Bus (IO-driven event collection + middleware) with
//! flux.Store (reducer-based state management) into a single tick()-driven
//! loop. Output (LED, display, speaker, etc.) is the caller's responsibility.
//!
//! The user defines an App type with:
//!   pub const State: type
//!   pub const Event: type          (union(enum), shared with Bus)
//!   pub fn reduce(*State, Event) void
//!
//! Usage:
//!   var rt = AppRuntime(MyApp, IO).init(allocator, &io, .{});
//!   try rt.register(&button.periph);
//!   rt.use(gesture.middleware());
//!   while (running) {
//!       rt.tick();
//!       if (rt.isDirty()) {
//!           // read rt.getState() / rt.getPrev(), drive any outputs
//!           rt.commitFrame();
//!       }
//!   }

const std = @import("std");
const flux = struct {
    pub fn Store(comptime State: type, comptime EventType: type) type {
        return @import("../flux/store.zig").Store(State, EventType);
    }
};
const event_pkg = struct {
    pub const types = @import("../event/types.zig");

    pub fn Bus(comptime IO: type, comptime EventType: type) type {
        return @import("../event/bus.zig").Bus(IO, EventType);
    }

    pub fn Periph(comptime EventType: type) type {
        return @import("../event/bus.zig").Periph(EventType);
    }

    pub fn Middleware(comptime EventType: type) type {
        return @import("../event/middleware.zig").Middleware(EventType);
    }
};

pub fn AppRuntime(comptime App: type, comptime IO: type) type {
    comptime {
        _ = @as(type, App.State);
        _ = @as(type, App.Event);
        _ = @as(*const fn (*App.State, App.Event) void, &App.reduce);
    }

    const EventType = App.Event;
    const StoreType = flux.Store(App.State, EventType);
    const BusType = event_pkg.Bus(IO, EventType);
    const PeriphType = event_pkg.Periph(EventType);
    const MiddlewareType = event_pkg.Middleware(EventType);

    return struct {
        const Self = @This();

        pub const Config = struct {
            initial_state: App.State = .{},
            poll_timeout_ms: i32 = 50,
        };

        store: StoreType,
        bus: BusType,
        poll_timeout_ms: i32,

        event_buf: [32]EventType = undefined,

        pub fn init(allocator: std.mem.Allocator, io: *IO, config: Config) Self {
            return .{
                .store = StoreType.init(config.initial_state, App.reduce),
                .bus = BusType.init(allocator, io),
                .poll_timeout_ms = config.poll_timeout_ms,
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit();
        }

        pub fn register(self: *Self, periph: *const PeriphType) !void {
            try self.bus.register(periph);
        }

        pub fn use(self: *Self, mw: MiddlewareType) void {
            self.bus.use(mw);
        }

        /// Single iteration: poll events → reduce.
        /// Check isDirty() afterwards to decide whether to update outputs.
        pub fn tick(self: *Self) void {
            const events = self.bus.poll(&self.event_buf, self.poll_timeout_ms);

            for (events) |ev| {
                self.store.dispatch(ev);
            }
        }

        /// Inject an event directly (bypasses IO/peripherals, goes straight to reducer).
        pub fn inject(self: *Self, ev: EventType) void {
            self.store.dispatch(ev);
        }

        pub fn getState(self: *const Self) *const App.State {
            return self.store.getState();
        }

        pub fn getPrev(self: *const Self) *const App.State {
            return self.store.getPrev();
        }

        pub fn isDirty(self: *const Self) bool {
            return self.store.isDirty();
        }

        /// Mark the current state as consumed. Call after you've driven outputs.
        pub fn commitFrame(self: *Self) void {
            self.store.commitFrame();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const runtime = struct {
    pub const std = @import("../../runtime/std.zig");
};
const StdIO = runtime.std.IO;

const TestApp = struct {
    pub const State = struct {
        count: u32 = 0,
    };

    pub const Event = union(enum) {
        tick,
        increment,
    };

    pub fn reduce(state: *State, ev: Event) void {
        switch (ev) {
            .tick => {},
            .increment => state.count += 1,
        }
    }
};

test "AppRuntime: inject dispatches to reducer" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();

    var rt = AppRuntime(TestApp, StdIO).init(
        testing.allocator,
        &io,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.inject(.increment);
    try testing.expectEqual(@as(u32, 1), rt.getState().count);
    try testing.expect(rt.isDirty());

    rt.commitFrame();
    try testing.expect(!rt.isDirty());
}

test "AppRuntime: tick with no events does not re-dirty" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();

    var rt = AppRuntime(TestApp, StdIO).init(
        testing.allocator,
        &io,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    io.wake();
    rt.tick();
    try testing.expect(!rt.isDirty());
}

test "AppRuntime: commitFrame resets dirty" {
    var io = try StdIO.init(testing.allocator);
    defer io.deinit();

    var rt = AppRuntime(TestApp, StdIO).init(
        testing.allocator,
        &io,
        .{ .poll_timeout_ms = 0 },
    );
    defer rt.deinit();

    rt.inject(.increment);
    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 1), rt.getState().count);

    rt.commitFrame();
    try testing.expect(!rt.isDirty());

    rt.inject(.increment);
    try testing.expect(rt.isDirty());
    try testing.expectEqual(@as(u32, 2), rt.getState().count);
}
