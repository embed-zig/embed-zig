const errors = @import("../error.zig");
const key_mod = @import("key.zig");
const types = @import("types.zig");

const c = @import("../c.zig").c;

pub fn raw(key: key_mod.Key, agreement_alg: types.Algorithm, peer_key: []const u8, out: []u8) errors.Error![]u8 {
    var len: usize = 0;
    try errors.check(c.psa_raw_key_agreement(agreement_alg, key.id, peer_key.ptr, peer_key.len, out.ptr, out.len, &len));
    return out[0..len];
}
