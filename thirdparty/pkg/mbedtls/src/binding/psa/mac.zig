const errors = @import("../error.zig");
const key_mod = @import("key.zig");
const types = @import("types.zig");

const c = @import("../c.zig").c;

pub fn compute(key: key_mod.Key, mac_alg: types.Algorithm, input: []const u8, out: []u8) errors.Error![]u8 {
    var len: usize = 0;
    try errors.check(c.psa_mac_compute(key.id, mac_alg, input.ptr, input.len, out.ptr, out.len, &len));
    return out[0..len];
}

pub const Operation = struct {
    storage: [c.EMBED_MBEDTLS_PSA_MAC_OPERATION_SIZE]u8 align(c.EMBED_MBEDTLS_PSA_MAC_OPERATION_ALIGN) = undefined,
    active: bool = false,

    pub fn signSetup(key: key_mod.Key, mac_alg: types.Algorithm) errors.Error!Operation {
        var op: Operation = .{};
        const raw_op = op.raw();
        c.embed_mbedtls_psa_mac_operation_init(raw_op);
        errdefer _ = c.psa_mac_abort(raw_op);
        try errors.check(c.psa_mac_sign_setup(raw_op, key.id, mac_alg));
        op.active = true;
        return op;
    }

    pub fn update(op: *Operation, input: []const u8) errors.Error!void {
        if (!op.active) return error.BadState;
        try errors.check(c.psa_mac_update(op.raw(), input.ptr, input.len));
    }

    pub fn signFinish(op: *Operation, out: []u8) errors.Error![]u8 {
        if (!op.active) return error.BadState;
        var len: usize = 0;
        errdefer op.abort();
        try errors.check(c.psa_mac_sign_finish(op.raw(), out.ptr, out.len, &len));
        op.active = false;
        return out[0..len];
    }

    pub fn abort(op: *Operation) void {
        if (!op.active) return;
        _ = c.psa_mac_abort(op.raw());
        op.active = false;
    }

    fn raw(op: *Operation) *c.psa_mac_operation_t {
        return @ptrCast(&op.storage);
    }
};
