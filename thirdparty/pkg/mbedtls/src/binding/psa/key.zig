const errors = @import("../error.zig");
const types = @import("types.zig");

const c = @import("../c.zig").c;

pub const KeyAttributes = struct {
    raw_attrs: c.psa_key_attributes_t,

    pub fn init() KeyAttributes {
        return .{ .raw_attrs = c.psa_key_attributes_init() };
    }

    pub fn deinit(self: *KeyAttributes) void {
        c.psa_reset_key_attributes(&self.raw_attrs);
    }

    pub fn setType(self: *KeyAttributes, value: types.KeyType) void {
        c.psa_set_key_type(&self.raw_attrs, value);
    }

    pub fn setBits(self: *KeyAttributes, bits: usize) void {
        c.psa_set_key_bits(&self.raw_attrs, bits);
    }

    pub fn setUsage(self: *KeyAttributes, value: types.Usage) void {
        c.psa_set_key_usage_flags(&self.raw_attrs, value);
    }

    pub fn setAlgorithm(self: *KeyAttributes, value: types.Algorithm) void {
        c.psa_set_key_algorithm(&self.raw_attrs, value);
    }

    pub fn raw(self: *KeyAttributes) *c.psa_key_attributes_t {
        return &self.raw_attrs;
    }
};

pub const Key = struct {
    id: types.KeyId,

    pub fn import(attrs: *KeyAttributes, data: []const u8) errors.Error!Key {
        try types.init();
        var id: types.KeyId = c.MBEDTLS_SVC_KEY_ID_INIT;
        try errors.check(c.psa_import_key(attrs.raw(), data.ptr, data.len, &id));
        return .{ .id = id };
    }

    pub fn generate(attrs: *KeyAttributes) errors.Error!Key {
        try types.init();
        var id: types.KeyId = c.MBEDTLS_SVC_KEY_ID_INIT;
        try errors.check(c.psa_generate_key(attrs.raw(), &id));
        return .{ .id = id };
    }

    pub fn deinit(self: *Key) void {
        _ = c.psa_destroy_key(self.id);
        self.id = c.MBEDTLS_SVC_KEY_ID_INIT;
    }

    pub fn exportPublic(self: Key, out: []u8) errors.Error![]u8 {
        var len: usize = 0;
        try errors.check(c.psa_export_public_key(self.id, out.ptr, out.len, &len));
        return out[0..len];
    }

    pub fn exportSecret(self: Key, out: []u8) errors.Error![]u8 {
        var len: usize = 0;
        try errors.check(c.psa_export_key(self.id, out.ptr, out.len, &len));
        return out[0..len];
    }

    pub fn macCompute(self: Key, mac_alg: types.Algorithm, input: []const u8, out: []u8) errors.Error![]u8 {
        return @import("mac.zig").compute(self, mac_alg, input, out);
    }

    pub fn rawAgreement(self: Key, agreement_alg: types.Algorithm, peer_key: []const u8, out: []u8) errors.Error![]u8 {
        return @import("agreement.zig").raw(self, agreement_alg, peer_key, out);
    }

    pub fn signHash(self: Key, sign_alg: types.Algorithm, hash: []const u8, sig: []u8) errors.Error![]u8 {
        return @import("sign.zig").signHash(self, sign_alg, hash, sig);
    }

    pub fn verifyHash(self: Key, sign_alg: types.Algorithm, hash: []const u8, sig: []const u8) errors.Error!void {
        try @import("sign.zig").verifyHash(self, sign_alg, hash, sig);
    }
};
