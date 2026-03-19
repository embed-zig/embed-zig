//! Thread contract — follows std.Thread conventions.
//!
//! Usage (after embed.Make):
//!   var t = try embed.Thread.spawn(.{}, myFunc, .{ &state, 42 });
//!   t.join();
//!
//!   embed.Thread.Mutex      — mutual exclusion lock
//!   embed.Thread.Condition   — condition variable
//!   embed.Thread.RwLock      — reader-writer lock

const std = @import("std");
const mutex_mod = @import("Thread/Mutex.zig");
const condition_mod = @import("Thread/Condition.zig");
const rwlock_mod = @import("Thread/RwLock.zig");

const root = @This();

pub const SpawnConfig = struct {
    stack_size: usize = 16384,
    priority: u8 = 5,
    name: [*:0]const u8 = "task",
    core_id: ?i32 = null,
};

pub const SpawnError = std.Thread.SpawnError;
pub const YieldError = std.Thread.YieldError;
pub const CpuCountError = std.Thread.CpuCountError;
pub const SetNameError = std.Thread.SetNameError;
pub const GetNameError = std.Thread.GetNameError;

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
///   const Id: type
///   const max_name_len: usize
///
/// Impl must also provide sub-types:
///   Mutex, Condition, RwLock
pub fn make(comptime Impl: type) type {
    comptime {
        if (Impl.max_name_len == 0 or Impl.max_name_len > 128)
            @compileError("Impl.max_name_len must be between 1 and 128");

        _ = @as(*const fn () YieldError!void, &Impl.yield);
        _ = @as(*const fn (u64) void, &Impl.sleep);
        _ = @as(*const fn () CpuCountError!usize, &Impl.getCpuCount);
        _ = @as(*const fn () Impl.Id, &Impl.getCurrentId);
        _ = @as(*const fn ([]const u8) SetNameError!void, &Impl.setName);
        _ = @as(*const fn (*[Impl.max_name_len:0]u8) GetNameError!?[]const u8, &Impl.getName);
    }

    return struct {
        pub const SpawnConfig = root.SpawnConfig;
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
            const inner = try Impl.spawn(config, f, args);
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
