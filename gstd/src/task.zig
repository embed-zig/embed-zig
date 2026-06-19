const glib = @import("glib");
const std = @import("std");

pub const impl = struct {
    pub fn make(comptime grt: type) type {
        const Pool = ThreadPool(grt);
        comptime var builder = glib.task.Builder();
        builder.handle("", Pool.DefaultHandler);
        builder.onError(Pool.ErrorHandler);
        return builder.make();
    }
};

pub fn ThreadPool(comptime grt: type) type {
    return struct {
        pub const SpawnError = grt.std.Thread.SpawnError;

        const Pool = @This();
        const allocator = std.heap.page_allocator;

        const State = struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            started: bool = false,
            worker_count: usize = 0,
            head: ?*Job = null,
            tail: ?*Job = null,
        };

        const Job = struct {
            next: ?*Job = null,
            run: *const fn (*Job) void,
        };

        const Shared = struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            state: Lifecycle = .running_joinable,
            destroy_fn: *const fn (*Shared) void,
        };

        const Lifecycle = enum {
            running_joinable,
            running_detached,
            finished_pending_join,
            finished_detached,
        };

        pub const Handle = struct {
            shared: *Shared,

            pub fn join(self: Handle) void {
                self.shared.mutex.lock();
                while (self.shared.state != .finished_pending_join) {
                    self.shared.cond.wait(&self.shared.mutex);
                }
                self.shared.state = .finished_detached;
                self.shared.mutex.unlock();

                self.shared.destroy_fn(self.shared);
            }

            pub fn detach(self: Handle) void {
                var destroy_now = false;

                self.shared.mutex.lock();
                switch (self.shared.state) {
                    .running_joinable => self.shared.state = .running_detached,
                    .finished_pending_join => {
                        self.shared.state = .finished_detached;
                        destroy_now = true;
                    },
                    .running_detached, .finished_detached => {},
                }
                self.shared.mutex.unlock();

                if (destroy_now) {
                    self.shared.destroy_fn(self.shared);
                }
            }
        };

        pub const DefaultHandler = struct {
            pub const Handle = Pool.Handle;
            pub const SpawnError = Pool.SpawnError;

            pub fn go(
                _: []const u8,
                _: glib.task.Options,
                routine: glib.task.Routine,
            ) Pool.SpawnError!Pool.Handle {
                return Pool.go(routine);
            }
        };

        pub const ErrorHandler = struct {
            pub fn onError(_: []const u8, _: anyerror) void {
                @panic("gstd task.go failed");
            }
        };

        pub fn go(routine: glib.task.Routine) SpawnError!Handle {
            const Packet = PacketType();
            const packet = allocator.create(Packet) catch return error.OutOfMemory;
            errdefer allocator.destroy(packet);

            packet.* = .{
                .job = .{ .run = Packet.runJob },
                .shared = .{ .destroy_fn = Packet.destroy },
                .routine = routine,
            };

            try ensureStarted();
            submit(&packet.job);

            return .{ .shared = &packet.shared };
        }

        fn PacketType() type {
            return struct {
                job: Job,
                shared: Shared,
                routine: glib.task.Routine,

                const Packet = @This();

                fn runJob(job: *Job) void {
                    const packet: *Packet = @fieldParentPtr("job", job);
                    packet.routine.run();
                    packet.finish();
                }

                fn finish(packet: *Packet) void {
                    var destroy_now = false;

                    packet.shared.mutex.lock();
                    switch (packet.shared.state) {
                        .running_joinable => {
                            packet.shared.state = .finished_pending_join;
                            packet.shared.cond.signal();
                        },
                        .running_detached => {
                            packet.shared.state = .finished_detached;
                            destroy_now = true;
                        },
                        .finished_pending_join, .finished_detached => {},
                    }
                    packet.shared.mutex.unlock();

                    if (destroy_now) {
                        Packet.destroy(&packet.shared);
                    }
                }

                fn destroy(shared: *Shared) void {
                    const packet: *Packet = @fieldParentPtr("shared", shared);
                    allocator.destroy(packet);
                }
            };
        }

        fn ensureStarted() SpawnError!void {
            global.state.mutex.lock();
            defer global.state.mutex.unlock();

            if (global.state.started) return;

            const target_count = defaultWorkerCount();
            var spawned: usize = 0;
            while (spawned < target_count) : (spawned += 1) {
                const worker = grt.std.Thread.spawn(.{}, workerMain, .{}) catch |err| {
                    if (spawned == 0) return err;
                    break;
                };
                worker.detach();
            }

            global.state.worker_count = spawned;
            global.state.started = true;
        }

        fn defaultWorkerCount() usize {
            const cpu_count = grt.system.cpuCount() catch 4;
            return @max(@as(usize, 1), @min(cpu_count, @as(usize, 4)));
        }

        fn submit(job: *Job) void {
            job.next = null;

            global.state.mutex.lock();
            if (global.state.tail) |tail| {
                tail.next = job;
            } else {
                global.state.head = job;
            }
            global.state.tail = job;
            global.state.cond.signal();
            global.state.mutex.unlock();
        }

        fn workerMain() void {
            while (true) {
                const job = take();
                job.run(job);
            }
        }

        fn take() *Job {
            global.state.mutex.lock();
            defer global.state.mutex.unlock();

            while (global.state.head == null) {
                global.state.cond.wait(&global.state.mutex);
            }

            const job = global.state.head.?;
            global.state.head = job.next;
            if (global.state.head == null) {
                global.state.tail = null;
            }
            job.next = null;
            return job;
        }

        const global = struct {
            var state: State = .{};
        };
    };
}
