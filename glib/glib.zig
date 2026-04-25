//! glib — application runtime namespace assembled at comptime.
//!
//! `glib.Runtime.make(...)` does not own platform behavior. It binds
//! already-selected platform capabilities into one application-facing
//! namespace.

pub const std = @import("stdz");
pub const testing = @import("testing");
pub const context = @import("context");
pub const sync = @import("sync");
pub const io = @import("io");
pub const mime = @import("mime");
pub const net = @import("net");
pub const Runtime = struct {
    const TypeMarker = struct {};
    pub const Options = struct {
        stdz_impl: type,
        channel_factory: @import("sync").channel.FactoryType,
        net_impl: type,
    };

    pub fn make(comptime options: Options) type {
        const std_ns = @import("stdz").make(options.stdz_impl);
        const channel_factory = options.channel_factory;
        const net_impl = options.net_impl;

        return struct {
            const runtime_marker: TypeMarker = .{};
            pub const std = std_ns;
            pub const context = @import("context").make(std_ns);
            pub const sync = struct {
                pub const ChannelFactory = channel_factory;
                pub const Channel = @import("sync").Channel(std_ns, channel_factory);

                pub fn Racer(comptime T: type) type {
                    return @import("sync").Racer(std_ns, T);
                }
            };
            pub const net = @import("net").make2(std_ns, net_impl);
        };
    }

    pub fn is(comptime ns: type) bool {
        switch (@typeInfo(ns)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => {},
            else => return false,
        }
        if (!@hasDecl(ns, "runtime_marker")) return false;
        return @TypeOf(ns.runtime_marker) == TypeMarker;
    }
};
