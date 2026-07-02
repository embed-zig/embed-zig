pub const runtime = struct {
    pub const sync = struct {
        pub const Mutex = @import("std").Thread.Mutex;
    };
};
