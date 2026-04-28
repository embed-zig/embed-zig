const std = @import("std");

const shared = @import("shared.zig");

var random_state = RandomState{};
pub const random = std.Random.init(&random_state, RandomState.fill);

const RandomState = struct {
    fn fill(_: *RandomState, buf: []u8) void {
        shared.psa_mutex.lock();
        defer shared.psa_mutex.unlock();
        shared.mbedtls.psa.types.random(buf) catch @panic("mbedTLS random failed");
    }
};
