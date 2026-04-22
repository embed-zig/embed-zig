const embed = @import("embed");
const builtin = embed.builtin;

pub const Context = @import("event/Context.zig");
pub const EventReceiver = @import("event/EventReceiver.zig");
const bt_event = @import("component/bt/event.zig");
const button_event = @import("component/button/event.zig");
const modem_event = @import("component/modem/event.zig");
const nfc_event = @import("component/nfc/event.zig");
const ui_flow_event = @import("component/ui/flow/event.zig");
const ui_overlay_event = @import("component/ui/overlay/event.zig");
const ui_route_event = @import("component/ui/route/event.zig");
const ui_selection_event = @import("component/ui/selection/event.zig");
const wifi_event = @import("component/wifi/event.zig");

pub fn make(comptime Events: anytype) type {
    const count = Events.len;

    comptime var enum_fields: [count]builtin.Type.EnumField = undefined;
    comptime var union_fields: [count]builtin.Type.UnionField = undefined;

    inline for (Events, 0..) |T, i| {
        const name = @tagName(T.kind);
        if (T.kind != .tick and (!@hasField(T, "source_id") or @FieldType(T, "source_id") != u32)) {
            @compileError("zux.event.make requires events except `tick` to expose `source_id: u32`");
        }
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
            .tag_type = if (count == 0) u0 else embed.math.IntFittingRange(0, count - 1),
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
    button_event.Single,
    button_event.Grouped,
    button_event.Detected,
    @import("component/ledstrip/event.zig").Set,
    @import("component/ledstrip/event.zig").SetPixels,
    @import("component/ledstrip/event.zig").Flash,
    @import("component/ledstrip/event.zig").Pingpong,
    @import("component/ledstrip/event.zig").Rotate,
    @import("component/imu/event.zig").Accel,
    @import("component/imu/event.zig").Gyro,
    @import("component/imu/event.zig").Motion,
    modem_event.SimStateChanged,
    modem_event.NetworkRegistrationChanged,
    modem_event.NetworkSignalChanged,
    modem_event.DataPacketStateChanged,
    modem_event.DataApnChanged,
    modem_event.CallIncoming,
    modem_event.CallStateChanged,
    modem_event.CallEnded,
    modem_event.SmsReceived,
    modem_event.GnssStateChanged,
    modem_event.GnssFixChanged,
    nfc_event.Found,
    nfc_event.Read,
    wifi_event.StaScanResult,
    wifi_event.StaConnected,
    wifi_event.StaDisconnected,
    wifi_event.StaGotIp,
    wifi_event.StaLostIp,
    wifi_event.ApStarted,
    wifi_event.ApStopped,
    wifi_event.ApClientJoined,
    wifi_event.ApClientLeft,
    wifi_event.ApLeaseGranted,
    wifi_event.ApLeaseReleased,
    bt_event.PeriphAdvertisingStarted,
    bt_event.PeriphAdvertisingStopped,
    bt_event.CentralFound,
    bt_event.CentralConnected,
    bt_event.CentralDisconnected,
    bt_event.CentralNotification,
    bt_event.PeriphConnected,
    bt_event.PeriphDisconnected,
    bt_event.PeriphMtuChanged,
    ui_flow_event.Move,
    ui_flow_event.Reset,
    ui_overlay_event.Show,
    ui_overlay_event.Hide,
    ui_overlay_event.SetName,
    ui_overlay_event.SetBlocking,
    ui_selection_event.Next,
    ui_selection_event.Prev,
    ui_selection_event.Set,
    ui_selection_event.Reset,
    ui_selection_event.SetCount,
    ui_selection_event.SetLoop,
    ui_route_event.Push,
    ui_route_event.Replace,
    ui_route_event.Reset,
    ui_route_event.Pop,
    ui_route_event.PopToRoot,
    ui_route_event.SetTransitioning,
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
