pub fn ThreadResult(comptime std: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        finished: bool = false,
        err: ?anyerror = null,

        const Self = @This();

        pub fn finish(self: *Self, err: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.err == null) self.err = err;
            self.finished = true;
            self.cond.broadcast();
        }

        pub fn wait(self: *Self) ?anyerror {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.finished) self.cond.wait(&self.mutex);
            return self.err;
        }
    };
}

pub fn ThreadSnapshot(comptime std: type, comptime Snapshot: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        finished: bool = false,
        err: ?anyerror = null,
        snapshot: Snapshot = .{},

        const Self = @This();

        pub fn finish(self: *Self, snapshot: Snapshot, err: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.snapshot = snapshot;
            if (self.err == null) self.err = err;
            self.finished = true;
            self.cond.broadcast();
        }

        pub fn wait(self: *Self) anyerror!Snapshot {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.finished) self.cond.wait(&self.mutex);
            if (self.err) |err| return err;
            return self.snapshot;
        }
    };
}
