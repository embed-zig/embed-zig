const std = @import("std");
const builtin = std.builtin;

pub const Context = @import("event/Context.zig");
pub const EventReceiver = @import("event/EventReceiver.zig");

pub fn make(comptime Events: anytype) type {
    const count = Events.len;

    comptime var enum_fields: [count]builtin.Type.EnumField = undefined;
    comptime var union_fields: [count]builtin.Type.UnionField = undefined;

    inline for (Events, 0..) |T, i| {
        const name = @tagName(T.kind);
        enum_fields[i] = .{
            .name = name,
            .value = i,
        };
        union_fields[i] = .{
            .name = name,
            .type = T,
            .alignment = @alignOf(T),
        };
    }

    const KindType = @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, count - 1),
            .fields = &enum_fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });

    return @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = KindType,
            .fields = &union_fields,
            .decls = &.{},
        },
    });
}

pub const Event = make(.{
    @import("pipeline/Tick.zig"),
    @import("button/Button.zig").Event,
    @import("button/GroupedButton.zig").Event,
    @import("button/GestureDetector.zig").Event,
    @import("imu/Accel.zig").Event,
    @import("imu/Gyro.zig").Event,
    @import("imu/MotionDetector.zig").Event,
    @import("Nfc.zig").FoundEvent,
    @import("Nfc.zig").ReadEvent,
    @import("Wifi.zig").StaScanResultEvent,
    @import("Wifi.zig").StaConnectedEvent,
    @import("Wifi.zig").StaDisconnectedEvent,
    @import("Bt.zig").PeriphAdvertisingStartedEvent,
    @import("Bt.zig").PeriphAdvertisingStoppedEvent,
    @import("Bt.zig").CentralFoundEvent,
    @import("Bt.zig").CentralConnectedEvent,
    @import("Bt.zig").CentralDisconnectedEvent,
    @import("Bt.zig").CentralNotificationEvent,
    @import("Bt.zig").PeriphConnectedEvent,
    @import("Bt.zig").PeriphDisconnectedEvent,
    @import("Bt.zig").PeriphMtuChangedEvent,
    @import("NetStack.zig").NetifCreatedEvent,
    @import("NetStack.zig").NetifDestroyedEvent,
    @import("NetStack.zig").NetifUpEvent,
    @import("NetStack.zig").NetifDownEvent,
    @import("NetStack.zig").AddrAddedEvent,
    @import("NetStack.zig").AddrRemovedEvent,
    @import("NetStack.zig").DhcpLeaseAcquiredEvent,
    @import("NetStack.zig").DhcpLeaseLostEvent,
    @import("NetStack.zig").DefaultRouteChangedEvent,
    @import("NetStack.zig").RouterDiscoveredEvent,
    @import("NetStack.zig").RouterLostEvent,
    @import("NetStack.zig").DnsServersChangedEvent,
    @import("NetStack.zig").PppPhaseChangedEvent,
    @import("NetStack.zig").PppAuthSucceededEvent,
    @import("NetStack.zig").PppAuthFailedEvent,
    @import("NetStack.zig").PppUpEvent,
    @import("NetStack.zig").PppDownEvent,
});

test {
    _ = @import("event/Context.zig");
    _ = @import("event/EventReceiver.zig");
    _ = @import("pipeline/Tick.zig");
}
