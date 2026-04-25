//! runtime — application runtime namespace assembled at comptime.
//!
//! `runtime.make(...)` does not own platform behavior. It binds already-selected
//! platform capabilities into one application-facing namespace.

const audio_mod = @import("audio");
const bt_mod = @import("bt");
const context_mod = @import("context");
const drivers_mod = @import("drivers");
const io_mod = @import("io");
const ledstrip_mod = @import("ledstrip");
const mime_mod = @import("mime");
const motion_mod = @import("motion");
const net_mod = @import("net");
const stdz_mod = @import("stdz");
const sync_mod = @import("sync");
const testing_mod = @import("testing");
const zux_mod = @import("zux");

const TypeMarker = struct {};
pub const Options = struct {
    stdz_impl: type,
    channel_factory: sync_mod.channel.FactoryType,
    net_impl: type,
};

pub fn make(comptime options: Options) type {
    const std_ns = stdz_mod.make(options.stdz_impl);
    const channel_factory = options.channel_factory;
    const net_impl = options.net_impl;

    return struct {
        const runtime_marker: TypeMarker = .{};
        pub const std = std_ns;
        pub const testing = testing_mod;
        pub const context = context_mod.make(std_ns);
        pub const sync = struct {
            pub const ChannelFactory = channel_factory;
            pub const Channel = sync_mod.Channel(std_ns, channel_factory);

            pub fn Racer(comptime T: type) type {
                return sync_mod.Racer(std_ns, T);
            }
        };
        pub const io = io_mod;
        pub const drivers = drivers_mod;
        pub const net = net_mod.make2(std_ns, net_impl);
        pub const mime = mime_mod;
        pub const bt = struct {
            const bound = bt_mod.make(std_ns, sync.Channel);

            pub const Central = bt_mod.Central;
            pub const Host = bt_mod.Host;
            pub const Peripheral = bt_mod.Peripheral;
            pub const GattConfig = bt_mod.GattConfig;
            pub const Transport = bt_mod.Transport;
            pub const Hci = bt_mod.Hci;
            pub const Mocker = bt_mod.Mocker;
            pub const make = bt_mod.make;

            pub const HciHost = bound.HciHost;
            pub const HciHostTransport = bound.HciHostTransport;
            pub const Server = bound.Server;
            pub const Client = bound.Client;
        };
        pub const motion = motion_mod;
        pub const audio = audio_mod;
        pub const ledstrip = ledstrip_mod;
        pub const zux = struct {
            pub const Store = zux_mod.Store;
            pub const ReducerFnType = zux_mod.ReducerFnType;
            pub const pipeline = zux_mod.pipeline;
            pub const events = zux_mod.events;
            pub const spec = zux_mod.spec;

            pub fn assemble(comptime config: anytype) type {
                return zux_mod.assemble(std_ns, config, sync.Channel);
            }
        };
    };
}

pub fn isRuntime(comptime Runtime: type) bool {
    if (!isContainer(Runtime)) return false;
    if (!@hasDecl(Runtime, "runtime_marker")) return false;
    return @TypeOf(Runtime.runtime_marker) == TypeMarker;
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}
