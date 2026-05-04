const glib = @import("glib");
const binding = @import("binding.zig");
const Thread = @import("../std/Thread.zig");

const ns_per_ms: i128 = 1_000_000;
const ns_per_s: i128 = 1_000_000_000;
const ns_per_s_u64: u64 = 1_000_000_000;
const ns_per_ms_i64: i64 = 1_000_000;
const ms_per_s: i64 = 1_000;
const max_i64: i64 = 9_223_372_036_854_775_807;

const Sample = struct {
    ns: u64,
    ms: u64,
};

var cache_lock: Thread.Mutex = .{};
var has_last_good_sample = false;
var last_good_ns: u64 = 0;
var last_good_ms: u64 = 0;

pub fn milliTimestamp() i64 {
    const sample = readMonotonic() orelse {
        const cached = loadCachedSample() orelse return 0;
        return @intCast(cached.ms);
    };
    return @intCast(sample.ms);
}

pub fn nanoTimestamp() i128 {
    const sample = readMonotonic() orelse {
        const cached = loadCachedSample() orelse return 0;
        return cached.ns;
    };
    return sample.ns;
}

pub fn wallNanoTimestamp() i128 {
    var ts: binding.timespec = undefined;
    if (binding.espz_newlib_clock_gettime_realtime(&ts) != 0) return 0;
    return timespecToNanoI128(ts);
}

fn readMonotonic() ?Sample {
    var ts: binding.timespec = undefined;
    if (binding.espz_newlib_clock_gettime_monotonic(&ts) != 0) {
        return null;
    }

    return updateCache(timespecToNano(ts), timespecToMilli(ts));
}

fn loadCachedSample() ?Sample {
    cache_lock.lock();
    defer cache_lock.unlock();
    if (!has_last_good_sample) return null;
    return .{
        .ns = last_good_ns,
        .ms = last_good_ms,
    };
}

fn updateCache(ns: u64, ms: u64) Sample {
    cache_lock.lock();
    defer cache_lock.unlock();
    has_last_good_sample = true;
    if (ns > last_good_ns) {
        last_good_ns = ns;
    }
    if (ms > last_good_ms) {
        last_good_ms = ms;
    }
    return .{
        .ns = last_good_ns,
        .ms = last_good_ms,
    };
}

fn timespecToNano(ts: binding.timespec) u64 {
    if (ts.tv_sec <= 0) return @intCast(@max(ts.tv_nsec, 0));

    const sec: u64 = @intCast(ts.tv_sec);
    const nsec: u64 = @intCast(@max(ts.tv_nsec, 0));
    if (sec >= @divFloor(glib.std.math.maxInt(u64) - nsec, ns_per_s_u64)) {
        return glib.std.math.maxInt(u64);
    }
    return sec * ns_per_s_u64 + nsec;
}

fn timespecToNanoI128(ts: binding.timespec) i128 {
    return (@as(i128, ts.tv_sec) * ns_per_s) + ts.tv_nsec;
}

fn timespecToMilli(ts: binding.timespec) u64 {
    const sec: i64 = ts.tv_sec;
    const sub_ms = @divFloor(@as(i64, ts.tv_nsec), ns_per_ms_i64);

    if (sec <= 0) return @intCast(@max(sub_ms, 0));
    if (sec >= @divFloor(max_i64 - sub_ms, ms_per_s)) return max_i64;
    return @intCast(sec * ms_per_s + sub_ms);
}
