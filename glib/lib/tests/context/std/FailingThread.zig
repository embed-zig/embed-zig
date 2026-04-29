//! Failing Thread namespace for context deadline spawn-failure tests.

pub fn make(comptime std: type) type {
    return struct {
        pub const SpawnConfig = std.Thread.SpawnConfig;
        pub const SpawnError = std.Thread.SpawnError;
        pub const YieldError = std.Thread.YieldError;
        pub const CpuCountError = std.Thread.CpuCountError;
        pub const SetNameError = std.Thread.SetNameError;
        pub const GetNameError = std.Thread.GetNameError;
        pub const max_name_len = std.Thread.max_name_len;
        pub const Id = std.Thread.Id;
        pub const Mutex = std.Thread.Mutex;
        pub const Condition = std.Thread.Condition;
        pub const RwLock = std.Thread.RwLock;

        const Self = @This();

        impl: u8 = 0,

        pub fn spawn(_: SpawnConfig, comptime _: anytype, _: anytype) SpawnError!Self {
            return error.SystemResources;
        }

        pub fn join(_: Self) void {}

        pub fn detach(_: Self) void {}

        pub fn yield() YieldError!void {
            return std.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            std.Thread.sleep(ns);
        }

        pub fn getCpuCount() CpuCountError!usize {
            return std.Thread.getCpuCount();
        }

        pub fn getCurrentId() Id {
            return std.Thread.getCurrentId();
        }

        pub fn setName(name: []const u8) SetNameError!void {
            return std.Thread.setName(name);
        }

        pub fn getName(buf: *[max_name_len:0]u8) GetNameError!?[]const u8 {
            return std.Thread.getName(buf);
        }
    };
}
