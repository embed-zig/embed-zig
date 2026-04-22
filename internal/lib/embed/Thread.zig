//! Thread contract — follows std.Thread conventions.
//!
//! Usage (after embed.make):
//!   var t = try embed.Thread.spawn(.{}, myFunc, .{ &state, 42 });
//!   t.join();
//!
//!   embed.Thread.Mutex      — mutual exclusion lock
//!   embed.Thread.Condition   — condition variable
//!   embed.Thread.RwLock      — reader-writer lock

const debug = @import("debug.zig");
const fmt = @import("fmt.zig");
const mutex_mod = @import("Thread/Mutex.zig");
const condition_mod = @import("Thread/Condition.zig");
const rwlock_mod = @import("Thread/RwLock.zig");
const mem = @import("mem.zig");
const posix = @import("posix.zig");

const std_compat = struct {
    pub const SpawnConfig = struct {
        /// Size in bytes of the Thread's stack. If 0, the default stack size will be used.
        stack_size: usize = 0,

        /// The allocator to be used to allocate memory for the to-be-spawned thread
        allocator: ?mem.Allocator = null,

        priority: u8 = 5,

        name: [*:0]const u8 = "task",

        core_id: ?i32 = null,
    };

    pub const SpawnError = error{
        ThreadQuotaExceeded,
        SystemResources,
        OutOfMemory,
        LockedMemoryLimitExceeded,
        Unexpected,
    };
    pub const YieldError = error{
        SystemCannotYield,
    };
    pub const CpuCountError = error{
        PermissionDenied,
        SystemResources,
        Unsupported,
        Unexpected,
    };
    pub const SetNameError = error{
        NameTooLong,
        Unsupported,
        Unexpected,
    } || posix.PrctlError || posix.WriteError || posix.FileOpenError || fmt.BufPrintError;
    pub const GetNameError = error{
        Unsupported,
        Unexpected,
    } || posix.PrctlError || posix.ReadError || posix.FileOpenError || fmt.BufPrintError;
};

const root = @This();

pub const SpawnConfig = std_compat.SpawnConfig;
pub const SpawnError = std_compat.SpawnError;
pub const YieldError = std_compat.YieldError;
pub const CpuCountError = std_compat.CpuCountError;
pub const SetNameError = std_compat.SetNameError;
pub const GetNameError = std_compat.GetNameError;
pub const Condition = condition_mod;

/// Construct a sealed Thread namespace from a platform Impl.
///
/// Impl must provide:
///   fn spawn(SpawnConfig, comptime anytype, anytype) SpawnError!Impl
///   fn join(Impl) void
///   fn detach(Impl) void
///   fn yield() YieldError!void
///   fn sleep(ns: u64) void
///   fn getCpuCount() CpuCountError!usize
///   fn getCurrentId() Id
///   fn setName(name: []const u8) SetNameError!void
///   fn getName(buf: *[max_name_len:0]u8) GetNameError!?[]const u8
///   const default_stack_size: usize
///   const Id: type
///   const max_name_len: usize
///
/// Impl must also provide sub-types:
///   Mutex, Condition, RwLock
pub fn make(comptime Impl: type, comptime Heap: type) type {
    comptime {
        if (Impl.max_name_len == 0 or Impl.max_name_len > 128)
            @compileError("Impl.max_name_len must be between 1 and 128");

        _ = @as(*const fn (Impl) void, &Impl.join);
        _ = @as(*const fn (Impl) void, &Impl.detach);
        _ = @as(*const fn () YieldError!void, &Impl.yield);
        _ = @as(*const fn (u64) void, &Impl.sleep);
        _ = @as(*const fn () CpuCountError!usize, &Impl.getCpuCount);
        _ = @as(*const fn () Impl.Id, &Impl.getCurrentId);
        _ = @as(*const fn ([]const u8) SetNameError!void, &Impl.setName);
        _ = @as(*const fn (*[Impl.max_name_len:0]u8) GetNameError!?[]const u8, &Impl.getName);
        _ = @as(usize, Impl.default_stack_size);
    }

    return struct {
        pub const SpawnConfig = root.SpawnConfig;
        pub const default_stack_size = Impl.default_stack_size;
        pub const SpawnError = root.SpawnError;
        pub const YieldError = root.YieldError;
        pub const CpuCountError = root.CpuCountError;
        pub const SetNameError = root.SetNameError;
        pub const GetNameError = root.GetNameError;
        pub const max_name_len = Impl.max_name_len;

        pub const Id = Impl.Id;

        pub const Mutex = mutex_mod.make(Impl.Mutex);
        pub const Condition = condition_mod.make(Impl.Condition);
        pub const RwLock = rwlock_mod.make(Impl.RwLock);

        impl: Impl,

        const Self = @This();

        pub fn spawn(config: root.SpawnConfig, comptime f: anytype, args: anytype) root.SpawnError!Self {
            var spawn_config = config;
            if (spawn_config.stack_size == 0) {
                spawn_config.stack_size = default_stack_size;
            }
            if (spawn_config.stack_size < Heap.pageSize()) {
                spawn_config.stack_size = Heap.pageSize();
            }
            debug.assert(spawn_config.stack_size >= Heap.pageSize());

            const inner = try Impl.spawn(spawn_config, f, args);
            return .{ .impl = inner };
        }

        pub fn join(self: Self) void {
            self.impl.join();
        }

        pub fn detach(self: Self) void {
            self.impl.detach();
        }

        pub fn yield() root.YieldError!void {
            return Impl.yield();
        }

        pub fn sleep(ns: u64) void {
            Impl.sleep(ns);
        }

        pub fn getCpuCount() root.CpuCountError!usize {
            return Impl.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return Impl.getCurrentId();
        }

        pub fn setName(name: []const u8) root.SetNameError!void {
            return Impl.setName(name);
        }

        pub fn getName(buf: *[Impl.max_name_len:0]u8) root.GetNameError!?[]const u8 {
            return Impl.getName(buf);
        }
    };
}

