//! HAL unified board event definitions.

/// Empty payload placeholder for absent optional event categories.
pub const Empty = struct {};

/// Board-level system events.
pub const SystemEvent = enum {
    ready,
    low_battery,
    sleep,
    wake,
    err,
};

/// Board-level timer event.
pub const TimerEvent = struct {
    id: u8,
    data: u32 = 0,
};

/// Generic unified board event union.
///
/// Use concrete payload types from HAL modules when available.
pub fn UnifiedEvent(
    comptime ButtonEventType: type,
    comptime WifiEventType: type,
    comptime BleEventType: type,
    comptime NetEventType: type,
    comptime MotionEventType: type,
) type {
    return union(enum) {
        button: ButtonEventType,
        wifi: WifiEventType,
        ble: BleEventType,
        net: NetEventType,
        motion: MotionEventType,
        timer: TimerEvent,
        system: SystemEvent,
    };
}

/// Default board event with all optional categories disabled.
pub const BoardEvent = UnifiedEvent(Empty, Empty, Empty, Empty, Empty);

test "UnifiedEvent can be instantiated" {
    const Evt = UnifiedEvent(u32, Empty, Empty, Empty, Empty);
    const ev = Evt{ .button = 42 };
    try @import("std").testing.expectEqual(@as(u32, 42), ev.button);
}
