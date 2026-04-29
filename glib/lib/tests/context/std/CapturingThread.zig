//! Capturing Thread namespace for context tests.

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

        impl: std.Thread = undefined,

        pub var sleep_calls: usize = 0;
        pub var last_sleep_ns: u64 = 0;

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            return .{ .impl = try std.Thread.spawn(config, f, args) };
        }

        pub fn join(self: Self) void {
            self.impl.join();
        }

        pub fn detach(self: Self) void {
            self.impl.detach();
        }

        pub fn yield() YieldError!void {
            return std.Thread.yield();
        }

        pub fn sleep(ns: u64) void {
            sleep_calls += 1;
            last_sleep_ns = ns;
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
