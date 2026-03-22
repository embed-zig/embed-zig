//! std compatibility test — exercises Thread, log, posix, net, time, atomic,
//! mem, fmt, collections, crypto, and random compatibility.
//!
//! Accepts any type with the same shape as std (lib.Thread, lib.log, lib.posix).
//! If this runs with std directly, it proves embed is a proper subset.
//!
//! Usage:
//!   try @import("embed").test_runner.std_compat.run(std);
//!   try @import("embed").test_runner.std_compat.run(embed);

const thread_runner = @import("std/thread.zig");
const log_runner = @import("std/log.zig");
const net_runner = @import("std/net.zig");
const posix_runner = @import("std/posix.zig");
const time_runner = @import("std/time.zig");
const atomic_runner = @import("std/atomic.zig");
const mem_runner = @import("std/mem.zig");
const fmt_runner = @import("std/fmt.zig");
const collections_runner = @import("std/collections.zig");
const crypto_runner = @import("std/crypto.zig");
const random_runner = @import("std/random.zig");

pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.test_runner);

    log.info("=== test_runner start ===", .{});

    try thread_runner.run(lib);
    try log_runner.run(lib);
    try net_runner.run(lib);
    try posix_runner.run(lib);
    try time_runner.run(lib);
    try atomic_runner.run(lib);
    try mem_runner.run(lib);
    try fmt_runner.run(lib);
    try collections_runner.run(lib);
    try crypto_runner.run(lib);
    try random_runner.run(lib);

    log.info("=== test_runner done ===", .{});
}

test "compact_test" {
    const std = @import("std");
    try run(std);
}
