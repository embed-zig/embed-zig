//! std runtime — validates all std implementations against runtime contracts.

const time_mod = @import("time.zig");
const log_mod = @import("log.zig");
const rng_mod = @import("rng.zig");
const sync_mod = @import("sync.zig");
const thread_mod = @import("thread.zig");
const system_mod = @import("system.zig");
const io_mod = @import("io.zig");
const socket_mod = @import("socket.zig");
const fs_mod = @import("fs.zig");
const netif_mod = @import("netif.zig");
const ota_backend_mod = @import("ota_backend.zig");
const crypto_mod = @import("crypto/root.zig");

const root = @import("std/root.zig");

test "std implementations satisfy all runtime contracts" {
    _ = time_mod.from(root.Time);
    _ = log_mod.from(root.Log);
    _ = rng_mod.from(root.Rng);
    _ = sync_mod.Mutex(root.Mutex);
    _ = sync_mod.ConditionWithMutex(root.Condition, root.Mutex);
    _ = sync_mod.Notify(root.Notify);
    _ = thread_mod.from(root.Thread);
    _ = system_mod.from(root.System);
    _ = io_mod.from(root.IO);
    _ = socket_mod.from(root.Socket);
    _ = fs_mod.from(root.Fs);
    _ = netif_mod.from(root.NetIf);
    _ = ota_backend_mod.from(root.OtaBackend);
    _ = crypto_mod.from(root.Crypto);
}

test {
    _ = @import("std/tests.zig");
}
