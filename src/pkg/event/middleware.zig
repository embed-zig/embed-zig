//! Event middleware — intercept, transform, or pass through events.
//!
//! Generic over EventType. A middleware is a pair of function pointers +
//! opaque context, following the same Allocator-style pattern used by `Periph`.
//!
//! `processFn` receives each event and an `emit` callback.
//!   - Call `emit(event)` to pass an event downstream (original or transformed).
//!   - Call `emit` zero times to swallow the event (buffering for later).
//!   - Call `emit` multiple times to fan-out.
//!
//! `tickFn` is called once per poll cycle so stateful middleware can flush
//! timeouts (e.g. confirm single-click after the double-click window expires).

pub fn Middleware(comptime EventType: type) type {
    return struct {
        ctx: ?*anyopaque,
        processFn: ?*const fn (ctx: ?*anyopaque, ev: EventType, emit_ctx: *anyopaque, emit: EmitFn(EventType)) void = null,
        tickFn: ?*const fn (ctx: ?*anyopaque, now_ms: u64, emit_ctx: *anyopaque, emit: EmitFn(EventType)) void = null,
    };
}

pub fn EmitFn(comptime EventType: type) type {
    return *const fn (ctx: *anyopaque, ev: EventType) void;
}
