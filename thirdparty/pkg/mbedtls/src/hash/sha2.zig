const shared = @import("../shared.zig");

const c = shared.c;
const checkMbed = shared.checkMbed;

pub const Sha256 = Sha256Impl;
pub const Sha384 = Sha512Impl(.sha384);
pub const Sha512 = Sha512Impl(.sha512);

const HashOptions = struct {};

const Sha256Impl = struct {
    pub const digest_length = 32;
    pub const block_length = 64;
    pub const Options = HashOptions;

    ctx: c.mbedtls_sha256_context,

    pub fn hash(input: []const u8, out: *[digest_length]u8, options: Options) void {
        var h = init(options);
        h.update(input);
        h.final(out);
    }

    pub fn init(_: Options) Sha256Impl {
        var self: Sha256Impl = undefined;
        c.mbedtls_sha256_init(&self.ctx);
        checkMbed(c.mbedtls_sha256_starts(&self.ctx, 0));
        return self;
    }

    pub fn update(self: *Sha256Impl, input: []const u8) void {
        checkMbed(c.mbedtls_sha256_update(&self.ctx, input.ptr, input.len));
    }

    pub fn final(self: *Sha256Impl, out: *[digest_length]u8) void {
        checkMbed(c.mbedtls_sha256_finish(&self.ctx, out));
        c.mbedtls_sha256_free(&self.ctx);
    }

    pub fn finalResult(self: *Sha256Impl) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        self.final(&out);
        return out;
    }

    pub fn peek(self: Sha256Impl) [digest_length]u8 {
        var clone: c.mbedtls_sha256_context = undefined;
        c.mbedtls_sha256_init(&clone);
        defer c.mbedtls_sha256_free(&clone);
        c.mbedtls_sha256_clone(&clone, &self.ctx);
        var out: [digest_length]u8 = undefined;
        checkMbed(c.mbedtls_sha256_finish(&clone, &out));
        return out;
    }
};

fn Sha512Impl(comptime mode: enum { sha384, sha512 }) type {
    return struct {
        pub const digest_length = if (mode == .sha384) 48 else 64;
        pub const block_length = 128;
        pub const Options = HashOptions;

        ctx: c.mbedtls_sha512_context,

        const Self = @This();

        pub fn hash(input: []const u8, out: *[digest_length]u8, options: Options) void {
            var h = init(options);
            h.update(input);
            h.final(out);
        }

        pub fn init(_: Options) Self {
            var self: Self = undefined;
            c.mbedtls_sha512_init(&self.ctx);
            checkMbed(c.mbedtls_sha512_starts(&self.ctx, if (mode == .sha384) 1 else 0));
            return self;
        }

        pub fn update(self: *Self, input: []const u8) void {
            checkMbed(c.mbedtls_sha512_update(&self.ctx, input.ptr, input.len));
        }

        pub fn final(self: *Self, out: *[digest_length]u8) void {
            checkMbed(c.mbedtls_sha512_finish(&self.ctx, out));
            c.mbedtls_sha512_free(&self.ctx);
        }

        pub fn finalResult(self: *Self) [digest_length]u8 {
            var out: [digest_length]u8 = undefined;
            self.final(&out);
            return out;
        }

        pub fn peek(self: Self) [digest_length]u8 {
            var clone: c.mbedtls_sha512_context = undefined;
            c.mbedtls_sha512_init(&clone);
            defer c.mbedtls_sha512_free(&clone);
            c.mbedtls_sha512_clone(&clone, &self.ctx);
            var out: [digest_length]u8 = undefined;
            checkMbed(c.mbedtls_sha512_finish(&clone, &out));
            return out;
        }
    };
}
