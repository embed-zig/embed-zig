const std = @import("std");
const armino = @import("bk_armino");
const condition_impl = @import("grt/sync/Condition.zig").Impl;
const mutex_impl = @import("grt/sync/Mutex.zig").Impl;
const rwlock_impl = @import("grt/sync/RwLock.zig").Impl;
const time_impl = @import("grt/time.zig");

test "bk sync backend satisfies glib sync contract" {
    comptime {
        if (@TypeOf(mutex_impl.lock) != fn (*mutex_impl) void) @compileError("BK Mutex.lock has invalid shape");
        if (@TypeOf(mutex_impl.unlock) != fn (*mutex_impl) void) @compileError("BK Mutex.unlock has invalid shape");
        if (@TypeOf(mutex_impl.tryLock) != fn (*mutex_impl) bool) @compileError("BK Mutex.tryLock has invalid shape");

        if (@TypeOf(condition_impl.wait) != fn (*condition_impl, *mutex_impl) void) @compileError("BK Condition.wait has invalid shape");
        if (@TypeOf(condition_impl.timedWait) != fn (*condition_impl, *mutex_impl, u64) error{Timeout}!void) @compileError("BK Condition.timedWait has invalid shape");
        if (@TypeOf(condition_impl.signal) != fn (*condition_impl) void) @compileError("BK Condition.signal has invalid shape");
        if (@TypeOf(condition_impl.broadcast) != fn (*condition_impl) void) @compileError("BK Condition.broadcast has invalid shape");

        if (@TypeOf(rwlock_impl.lockShared) != fn (*rwlock_impl) void) @compileError("BK RwLock.lockShared has invalid shape");
        if (@TypeOf(rwlock_impl.unlockShared) != fn (*rwlock_impl) void) @compileError("BK RwLock.unlockShared has invalid shape");
        if (@TypeOf(rwlock_impl.lock) != fn (*rwlock_impl) void) @compileError("BK RwLock.lock has invalid shape");
        if (@TypeOf(rwlock_impl.unlock) != fn (*rwlock_impl) void) @compileError("BK RwLock.unlock has invalid shape");
        if (@TypeOf(rwlock_impl.tryLockShared) != fn (*rwlock_impl) bool) @compileError("BK RwLock.tryLockShared has invalid shape");
        if (@TypeOf(rwlock_impl.tryLock) != fn (*rwlock_impl) bool) @compileError("BK RwLock.tryLock has invalid shape");

        if (@hasDecl(mutex_impl, "Thread")) @compileError("BK sync Mutex must not expose Thread");
        if (@hasDecl(condition_impl, "Thread")) @compileError("BK sync Condition must not expose Thread");
        if (@hasDecl(rwlock_impl, "Thread")) @compileError("BK sync RwLock must not expose Thread");
    }
}

test "bk time backend satisfies glib time contract" {
    comptime {
        if (!@hasDecl(time_impl, "instant")) @compileError("missing BK instant time backend");
        if (!@hasDecl(time_impl.instant, "now")) @compileError("missing BK instant now");
        if (!@hasDecl(time_impl, "wall")) @compileError("missing BK wall time backend");
        if (!@hasDecl(time_impl.wall, "now")) @compileError("missing BK wall now");
        if (!@hasDecl(time_impl.wall, "set")) @compileError("missing BK wall set");
        if (!@hasDecl(time_impl, "sleep")) @compileError("missing BK sleep backend");
        if (!@hasDecl(time_impl.sleep, "sleep")) @compileError("missing BK sleep function");
    }
}

test "bk armino exports compile" {
    _ = armino.BuildContext;
    _ = armino.Config;
    _ = armino.Component;
    _ = armino.DualCoreApp;
    _ = armino.PartitionTable;
    _ = armino.RamRegions;
    _ = armino.ipc;
    _ = armino.system;
}

test "bk armino config render prints supported entries" {
    const cfg = armino.Config.make(.{
        .MAILBOX = true,
        .DISABLED = false,
        .UART_PRINT_PORT = 0,
        .NAME = "bk",
        .OFFSET = armino.Config.raw("0x8000"),
    });
    const text = try armino.Config.render(std.testing.allocator, cfg);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONFIG_MAILBOX=y") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# CONFIG_DISABLED is not set") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONFIG_UART_PRINT_PORT=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONFIG_NAME=\"bk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONFIG_OFFSET=0x8000") != null);
}

test "bk armino partition table renders csv and derived config" {
    const csv_table = armino.PartitionTable.make(.{
        .entries = &.{
            .{
                .name = "primary_bootloader",
                .size = armino.PartitionTable.rawSize("68k"),
                .kind = .code,
                .read = true,
                .write = false,
            },
            .{
                .name = "easyflash",
                .offset = 0x7fa000,
                .size = armino.PartitionTable.kb(8),
                .kind = .data,
                .read = true,
                .write = true,
            },
        },
    });
    const csv = try armino.PartitionTable.renderCsv(std.testing.allocator, csv_table);
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "primary_bootloader,,68k,code,TRUE,FALSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "easyflash,0x7fa000,8K,data,TRUE,TRUE") != null);

    const derived_table = armino.PartitionTable.make(.{
        .entries = &.{
            .{
                .name = "littlefs",
                .offset = 0x780000,
                .size = armino.PartitionTable.kb(256),
                .kind = .data,
                .read = true,
                .write = true,
                .data = armino.PartitionTable.data.littlefs(.{ .source_dir = "partitions/littlefs" }),
            },
            .{
                .name = "flashdb_kv",
                .offset = 0x7c0000,
                .size = armino.PartitionTable.rawSize("128K"),
                .kind = .data,
                .read = true,
                .write = true,
                .data = armino.PartitionTable.data.flashdbKv(.{}),
            },
        },
    });
    const derived = try armino.PartitionTable.renderDerivedConfig(std.testing.allocator, derived_table, .ap);
    defer std.testing.allocator.free(derived);
    try std.testing.expect(std.mem.indexOf(u8, derived, "CONFIG_LITTLEFS=y") != null);
    try std.testing.expect(std.mem.indexOf(u8, derived, "CONFIG_FLASHDB=y") != null);
    try std.testing.expect(std.mem.indexOf(u8, derived, "CONFIG_FLASHDB_KVDB_START_ADDR=0x7c0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, derived, "CONFIG_FLASHDB_KVDB_SIZE=0x20000") != null);
}

test "bk armino ram regions render csv" {
    const table = armino.RamRegions.make(.{
        .regions = &.{
            .{
                .name = "AP_SPINLOCK",
                .kind = .SRAM,
                .offset = 0x28000000,
                .size = armino.RamRegions.bytes(0x010000),
            },
            .{
                .name = "AP_RAM",
                .kind = .SRAM,
                .size = armino.RamRegions.rawSize("0x054000"),
            },
        },
    });
    const text = try armino.RamRegions.renderCsv(std.testing.allocator, table);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "PSRAM_CAPCAITY_SIZE=8M") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AP_SPINLOCK,SRAM,0x28000000,0x010000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AP_RAM,SRAM,,0x054000") != null);
}
