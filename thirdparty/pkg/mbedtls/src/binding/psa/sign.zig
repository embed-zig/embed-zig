const errors = @import("../error.zig");
const key_mod = @import("key.zig");
const types = @import("types.zig");

const c = @import("../c.zig").c;

pub fn signHash(key: key_mod.Key, sign_alg: types.Algorithm, hash: []const u8, sig: []u8) errors.Error![]u8 {
    var len: usize = 0;
    try errors.check(c.psa_sign_hash(key.id, sign_alg, hash.ptr, hash.len, sig.ptr, sig.len, &len));
    return sig[0..len];
}

pub fn verifyHash(key: key_mod.Key, sign_alg: types.Algorithm, hash: []const u8, sig: []const u8) errors.Error!void {
    try errors.check(c.psa_verify_hash(key.id, sign_alg, hash.ptr, hash.len, sig.ptr, sig.len));
}
