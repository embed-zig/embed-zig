const glib = @import("glib");
const builtin = @import("builtin");
const binding = @import("binding.zig");
const atomic = @import("../std/atomic.zig");

const ns_per_us: u64 = 1_000;
const sub_ns_bits = 10;
const sub_ns_mask = (1 << sub_ns_bits) - 1;
const max_sub_ns = ns_per_us - 1;

const State = struct {
    raw_state: u64,
    ns: u64,
};

var last_instant_state: atomic.Value(u64) = atomic.Value(u64).init(0);

pub const TestSupport = if (builtin.is_test) struct {
    pub fn nextStateForUs(previous_state: u64, us: u64) State {
        return nextState(previous_state, us);
    }
} else struct {};

pub const Instant = struct {
    timestamp: u64,

    pub fn now() error{Unsupported}!Instant {
        return .{ .timestamp = instantNow() };
    }

    pub fn order(self: Instant, other: Instant) glib.std.math.Order {
        return glib.std.math.order(self.timestamp, other.timestamp);
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        if (self.timestamp <= earlier.timestamp) return 0;
        return self.timestamp - earlier.timestamp;
    }
};

pub fn instantNow() u64 {
    return uptimeNs();
}

fn uptimeUs() i64 {
    const us = binding.espz_grt_time_uptime_us();
    return if (us > 0) us else 0;
}

fn uptimeNs() u64 {
    const us: u64 = @intCast(uptimeUs());
    while (true) {
        const previous_state = last_instant_state.load(.acquire);
        const next = nextState(previous_state, us);

        if (last_instant_state.cmpxchgWeak(previous_state, next.raw_state, .acq_rel, .acquire) == null) {
            return next.ns;
        }
    }
}

fn instantNs(us: u64, sub_ns: u64) u64 {
    const base_ns = if (us > @divFloor(glib.std.math.maxInt(u64), ns_per_us))
        glib.std.math.maxInt(u64)
    else
        us * ns_per_us;

    const ns, const overflowed = @addWithOverflow(base_ns, sub_ns);
    if (overflowed != 0) {
        return glib.std.math.maxInt(u64);
    }
    return ns;
}

fn nextState(previous_state: u64, us: u64) State {
    const previous_us = previous_state >> sub_ns_bits;
    const previous_sub_ns = previous_state & sub_ns_mask;

    const next_sub_ns = if (us == previous_us)
        @min(previous_sub_ns + 1, max_sub_ns)
    else
        0;

    return .{
        .raw_state = (us << sub_ns_bits) | next_sub_ns,
        .ns = instantNs(us, next_sub_ns),
    };
}
