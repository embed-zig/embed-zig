const std = @import("std");

var library: ?*std.Build.Step.Compile = null;

/// Mbed TLS release archives include generated C files missing from source tags.
const upstream_tarball_url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-4.1.0/mbedtls-4.1.0.tar.bz2";
const upstream_version_key = "mbedtls-4.1.0";
const crypto_tarball_url = "https://github.com/Mbed-TLS/TF-PSA-Crypto/releases/download/tf-psa-crypto-1.1.0/tf-psa-crypto-1.1.0.tar.bz2";
const crypto_version_key = "tf-psa-crypto-1.1.0";

const upstream_include_dirs: []const []const u8 = &.{
    "include",
    "library",
    "framework/include",
};

const upstream_c_sources: []const []const u8 = &.{
    "library/debug.c",
    "library/mps_reader.c",
    "library/mps_trace.c",
    "library/pkcs7.c",
    "library/ssl_cache.c",
    "library/ssl_ciphersuites.c",
    "library/ssl_client.c",
    "library/ssl_cookie.c",
    "library/ssl_debug_helpers_generated.c",
    "library/ssl_msg.c",
    "library/ssl_ticket.c",
    "library/ssl_tls.c",
    "library/ssl_tls12_client.c",
    "library/ssl_tls12_server.c",
    "library/ssl_tls13_client.c",
    "library/ssl_tls13_generic.c",
    "library/ssl_tls13_keys.c",
    "library/ssl_tls13_server.c",
    "library/timing.c",
    "library/version.c",
    "library/x509.c",
    "library/x509_create.c",
    "library/x509_crl.c",
    "library/x509_crt.c",
    "library/x509_csr.c",
    "library/x509_oid.c",
    "library/x509write.c",
    "library/x509write_crt.c",
    "library/x509write_csr.c",
};

const crypto_include_dirs: []const []const u8 = &.{
    "include",
    "core",
    "dispatch",
    "extras",
    "platform",
    "utilities",
    "drivers/builtin/include",
    "drivers/builtin/src",
    "drivers/everest/include",
    "drivers/everest/include/tf-psa-crypto/private/everest",
    "drivers/everest/include/tf-psa-crypto/private/everest/kremlib",
    "drivers/p256-m",
    "drivers/p256-m/p256-m",
    "drivers/pqcp/include",
};

const crypto_c_sources: []const []const u8 = &.{
    "core/psa_crypto_client.c",
    "core/psa_crypto_driver_wrappers_no_static.c",
    "core/psa_crypto_slot_management.c",
    "core/psa_util.c",
    "core/tf_psa_crypto_version.c",
    "core/psa_its_file.c",
    "core/psa_crypto.c",
    "core/psa_crypto_storage.c",
    "core/psa_crypto_random.c",
    "platform/platform.c",
    "platform/platform_util.c",
    "platform/memory_buffer_alloc.c",
    "platform/threading.c",
    "utilities/constant_time.c",
    "utilities/asn1parse.c",
    "utilities/asn1write.c",
    "utilities/pkcs5.c",
    "utilities/pem.c",
    "utilities/oid.c",
    "utilities/base64.c",
    "extras/pk_wrap.c",
    "extras/pk.c",
    "extras/pkwrite.c",
    "extras/lms.c",
    "extras/pk_ecc.c",
    "extras/pkparse.c",
    "extras/pk_rsa.c",
    "extras/lmots.c",
    "extras/md.c",
    "extras/nist_kw.c",
    "drivers/p256-m/p256-m_driver_entrypoints.c",
    "drivers/everest/library/Hacl_Curve25519.c",
    "drivers/everest/library/x25519.c",
    "drivers/everest/library/Hacl_Curve25519_joined.c",
    "drivers/everest/library/kremlib/FStar_UInt64_FStar_UInt32_FStar_UInt16_FStar_UInt8.c",
    "drivers/p256-m/p256-m/p256-m.c",
    "drivers/builtin/src/aes.c",
    "drivers/builtin/src/bignum_mod_raw.c",
    "drivers/builtin/src/block_cipher.c",
    "drivers/builtin/src/camellia.c",
    "drivers/builtin/src/aesce.c",
    "drivers/builtin/src/cipher_wrap.c",
    "drivers/builtin/src/chacha20.c",
    "drivers/builtin/src/psa_crypto_rsa.c",
    "drivers/builtin/src/ctr_drbg.c",
    "drivers/builtin/src/psa_crypto_mac.c",
    "drivers/builtin/src/aesni.c",
    "drivers/builtin/src/ecp_curves_new.c",
    "drivers/builtin/src/hmac_drbg.c",
    "drivers/builtin/src/rsa.c",
    "drivers/builtin/src/gcm.c",
    "drivers/builtin/src/sha1.c",
    "drivers/builtin/src/ccm.c",
    "drivers/builtin/src/aria.c",
    "drivers/builtin/src/psa_crypto_cipher.c",
    "drivers/builtin/src/entropy_poll.c",
    "drivers/builtin/src/cmac.c",
    "drivers/builtin/src/bignum.c",
    "drivers/builtin/src/psa_crypto_ffdh.c",
    "drivers/builtin/src/ripemd160.c",
    "drivers/builtin/src/bignum_mod.c",
    "drivers/builtin/src/psa_crypto_pake.c",
    "drivers/builtin/src/rsa_alt_helpers.c",
    "drivers/builtin/src/psa_crypto_xof.c",
    "drivers/builtin/src/psa_crypto_aead.c",
    "drivers/builtin/src/ecp.c",
    "drivers/builtin/src/bignum_core.c",
    "drivers/builtin/src/chachapoly.c",
    "drivers/builtin/src/sha256.c",
    "drivers/builtin/src/ecp_curves.c",
    "drivers/builtin/src/md5.c",
    "drivers/builtin/src/chacha20_neon.c",
    "drivers/builtin/src/psa_crypto_ecp.c",
    "drivers/builtin/src/poly1305.c",
    "drivers/builtin/src/sha3.c",
    "drivers/builtin/src/psa_util_internal.c",
    "drivers/builtin/src/psa_crypto_hash.c",
    "drivers/builtin/src/entropy.c",
    "drivers/builtin/src/sha512.c",
    "drivers/builtin/src/ecjpake.c",
    "drivers/builtin/src/cipher.c",
    "drivers/builtin/src/ecdsa.c",
    "drivers/pqcp/src/wrap_mldsa_native.c",
    "drivers/pqcp/src/psa_crypto_mldsa.c",
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const upstream = addReleaseArchive(b, .{
        .url = upstream_tarball_url,
        .version_key = upstream_version_key,
        .cache_namespace = "mbedtls-upstream",
        .step_name = "mbedtls.fetch-archive.ensure",
    });
    const crypto_upstream = addReleaseArchive(b, .{
        .url = crypto_tarball_url,
        .version_key = crypto_version_key,
        .cache_namespace = "tf-psa-crypto-upstream",
        .step_name = "tf-psa-crypto.fetch-archive.ensure",
    });
    crypto_upstream.ready.dependOn(upstream.ready);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mbedtls",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    addCommonInputs(b, lib.root_module, upstream, crypto_upstream);
    addLibrarySources(lib.root_module, upstream, crypto_upstream);
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/mbedtls/src/binding/binding.c") });
    crypto_upstream.dependOn(&lib.step);

    const mod = b.addModule("mbedtls", .{
        .root_source_file = b.path("pkg/mbedtls.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCommonInputs(b, mod, upstream, crypto_upstream);
    library = lib;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("mbedtls") orelse @panic("mbedtls module missing");
    const lib = library orelse @panic("mbedtls library missing");
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addObjectFile(lib.getEmittedBin());
}

fn addCommonInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: ReleaseArchive,
    crypto_upstream: ReleaseArchive,
) void {
    mod.addCMacro("MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS", "");
    mod.addIncludePath(b.path("pkg/mbedtls/src"));
    for (upstream_include_dirs) |dir| {
        mod.addIncludePath(upstream.includePath(dir));
    }
    for (crypto_include_dirs) |dir| {
        mod.addIncludePath(crypto_upstream.includePath(dir));
    }
}

fn addLibrarySources(
    mod: *std.Build.Module,
    upstream: ReleaseArchive,
    crypto_upstream: ReleaseArchive,
) void {
    for (upstream_c_sources) |src| {
        mod.addCSourceFile(.{ .file = upstream.sourcePath(src) });
    }
    for (crypto_c_sources) |src| {
        mod.addCSourceFile(.{ .file = crypto_upstream.sourcePath(src) });
    }
}

const ReleaseArchive = struct {
    b: *std.Build,
    prefix_path: []const u8,
    ready: *std.Build.Step,

    pub fn root(self: ReleaseArchive) std.Build.LazyPath {
        return .{ .cwd_relative = self.prefix_path };
    }

    pub fn path(self: ReleaseArchive, sub_path: []const u8) std.Build.LazyPath {
        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".")) {
            return self.root();
        }
        return .{ .cwd_relative = std.fs.path.join(self.b.allocator, &.{ self.prefix_path, sub_path }) catch @panic("OOM") };
    }

    pub fn sourcePath(self: ReleaseArchive, sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    pub fn includePath(self: ReleaseArchive, sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    pub fn dependOn(self: ReleaseArchive, step: *std.Build.Step) void {
        step.dependOn(self.ready);
    }
};

const ReleaseEnsureStep = struct {
    step: std.Build.Step,
    prefix_path: []const u8,
    url: []const u8,
    version_key: []const u8,

    fn create(
        b: *std.Build,
        step_name: []const u8,
        prefix_path: []const u8,
        url: []const u8,
        version_key: []const u8,
    ) *ReleaseEnsureStep {
        const self = b.allocator.create(ReleaseEnsureStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = step_name,
                .owner = b,
                .makeFn = make,
            }),
            .prefix_path = b.dupe(prefix_path),
            .url = b.dupe(url),
            .version_key = b.dupe(version_key),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        const self: *ReleaseEnsureStep = @alignCast(@fieldParentPtr("step", step));
        var arena = std.heap.ArenaAllocator.init(options.gpa);
        defer arena.deinit();
        try ensureReleaseArchive(arena.allocator(), self.prefix_path, self.url, self.version_key);
    }
};

fn addReleaseArchive(
    b: *std.Build,
    opts: struct {
        url: []const u8,
        version_key: []const u8,
        cache_namespace: []const u8,
        step_name: []const u8,
    },
) ReleaseArchive {
    const prefix_path = b.cache_root.join(b.allocator, &.{
        opts.cache_namespace,
        opts.version_key,
    }) catch @panic("OOM");

    const ensure_step = ReleaseEnsureStep.create(b, opts.step_name, prefix_path, opts.url, opts.version_key);
    return .{ .b = b, .prefix_path = prefix_path, .ready = &ensure_step.step };
}

fn ensureReleaseArchive(gpa: std.mem.Allocator, dest_dir: []const u8, url: []const u8, version_key: []const u8) !void {
    const dest_abs = if (std.fs.path.isAbsolute(dest_dir))
        try gpa.dupe(u8, dest_dir)
    else blk: {
        const cwd_abs = try std.fs.cwd().realpathAlloc(gpa, ".");
        defer gpa.free(cwd_abs);
        break :blk try std.fs.path.join(gpa, &.{ cwd_abs, dest_dir });
    };
    defer gpa.free(dest_abs);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{dest_abs});
    defer gpa.free(lock_path);

    const parent = std.fs.path.dirname(dest_abs) orelse ".";
    try std.fs.cwd().makePath(parent);

    var lock = try std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer lock.close();

    if (try markerMatches(gpa, dest_abs, version_key)) return;

    std.fs.deleteTreeAbsolute(dest_abs) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var uniq: [8]u8 = undefined;
    std.crypto.random.bytes(&uniq);
    const tmp_name = try std.fmt.allocPrint(gpa, ".release-archive-tmp.{s}", .{std.fmt.bytesToHex(uniq, .lower)});
    const archive_name = try std.fmt.allocPrint(gpa, ".release-archive.{s}.tar.bz2", .{std.fmt.bytesToHex(uniq, .lower)});
    const tmp_path = try std.fs.path.join(gpa, &.{ parent, tmp_name });
    const archive_path = try std.fs.path.join(gpa, &.{ parent, archive_name });
    defer std.fs.deleteFileAbsolute(archive_path) catch {};

    try std.fs.makeDirAbsolute(tmp_path);
    errdefer std.fs.deleteTreeAbsolute(tmp_path) catch {};

    try runCommand(gpa, &.{ "curl", "-fsSL", "-o", archive_path, url });
    try runCommand(gpa, &.{ "tar", "-xjf", archive_path, "--strip-components", "1", "-C", tmp_path });

    try std.fs.renameAbsolute(tmp_path, dest_abs);

    var dest_handle = try std.fs.openDirAbsolute(dest_abs, .{});
    defer dest_handle.close();
    try dest_handle.writeFile(.{ .sub_path = ".fetch-archive-version", .data = version_key, .flags = .{} });
}

fn markerMatches(gpa: std.mem.Allocator, dest_abs: []const u8, version_key: []const u8) !bool {
    var dest_dir = std.fs.openDirAbsolute(dest_abs, .{}) catch return false;
    defer dest_dir.close();

    const prev = dest_dir.readFileAlloc(gpa, ".fetch-archive-version", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer gpa.free(prev);

    const trimmed = std.mem.trimRight(u8, prev, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, version_key);
}

fn runCommand(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    if (result.stderr.len != 0) {
        std.log.err("command failed: {s}", .{result.stderr});
    }
    return error.CommandFailed;
}
