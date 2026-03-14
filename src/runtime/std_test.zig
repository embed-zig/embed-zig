const std = @import("std");
const module = @import("std.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Time = module.Time;
const Log = module.Log;
const Rng = module.Rng;
const Mutex = module.Mutex;
const Condition = module.Condition;
const Notify = module.Notify;
const Thread = module.Thread;
const System = module.System;
const Fs = module.Fs;
const Socket = module.Socket;
const NetIf = module.NetIf;
const OtaBackend = module.OtaBackend;
const Crypto = module.Crypto;
const std_time = test_exports.std_time;
const std_log = test_exports.std_log;
const std_rng = test_exports.std_rng;
const std_sync = test_exports.std_sync;
const std_thread = test_exports.std_thread;
const std_system = test_exports.std_system;
const std_fs = test_exports.std_fs;
const std_socket = test_exports.std_socket;
const std_netif = test_exports.std_netif;
const std_ota_backend = test_exports.std_ota_backend;
const std_crypto_hash = test_exports.std_crypto_hash;
const std_crypto_hmac = test_exports.std_crypto_hmac;
const std_crypto_hkdf = test_exports.std_crypto_hkdf;
const std_crypto_aead = test_exports.std_crypto_aead;
const std_crypto_pki = test_exports.std_crypto_pki;
const std_crypto_rsa = test_exports.std_crypto_rsa;
const std_crypto_kex = test_exports.std_crypto_kex;
const std_crypto_x509 = test_exports.std_crypto_x509;


const time_mod = @import("time.zig");
const log_mod = @import("log.zig");
const rng_mod = @import("rng.zig");
const sync_mod = @import("sync.zig");
const thread_mod = @import("thread.zig");
const system_mod = @import("system.zig");
const socket_mod = @import("socket.zig");
const fs_mod = @import("fs.zig");
const netif_mod = @import("netif.zig");
const ota_backend_mod = @import("ota_backend.zig");
const crypto_mod = @import("crypto/suite.zig");

test "std implementations satisfy all runtime contracts" {
    _ = time_mod.from(Time);
    _ = log_mod.from(Log);
    _ = rng_mod.from(Rng);
    _ = sync_mod.Mutex(Mutex);
    _ = sync_mod.ConditionWithMutex(Condition, Mutex);
    _ = sync_mod.Notify(Notify);
    _ = thread_mod.from(Thread);
    _ = system_mod.from(System);
    _ = socket_mod.from(Socket);
    _ = fs_mod.from(Fs);
    _ = netif_mod.from(NetIf);
    _ = ota_backend_mod.from(OtaBackend);
    _ = crypto_mod.from(Crypto);
}

test {
    _ = @import("std/tests_test.zig");
}
