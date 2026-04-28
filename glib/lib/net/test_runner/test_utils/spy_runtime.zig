const runtime = @import("../../runtime.zig");

pub fn make(comptime std: type, comptime Base: type) type {
    const AtomicUsize = std.atomic.Value(usize);

    return struct {
        pub var tcp_create_count: AtomicUsize = AtomicUsize.init(0);
        pub var udp_create_count: AtomicUsize = AtomicUsize.init(0);

        pub const Tcp = Base.Tcp;
        pub const Udp = Base.Udp;

        pub fn reset() void {
            tcp_create_count.store(0, .release);
            udp_create_count.store(0, .release);
        }

        pub fn tcpCreateCount() usize {
            return tcp_create_count.load(.acquire);
        }

        pub fn udpCreateCount() usize {
            return udp_create_count.load(.acquire);
        }

        pub fn tcp(domain: runtime.Domain) runtime.CreateError!Tcp {
            _ = tcp_create_count.fetchAdd(1, .monotonic);
            return Base.tcp(domain);
        }

        pub fn udp(domain: runtime.Domain) runtime.CreateError!Udp {
            _ = udp_create_count.fetchAdd(1, .monotonic);
            return Base.udp(domain);
        }
    };
}
