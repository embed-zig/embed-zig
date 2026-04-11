const embed = @import("embed");
const EventReceiver = @import("../event.zig").EventReceiver;
const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const Node = @import("Node.zig");
const sync = @import("sync");
const testing_api = @import("testing");

pub fn Config(comptime lib: type) type {
    return struct {
        tick_interval_ns: u64 = 10 * embed.time.ns_per_ms,
        spawn_config: lib.Thread.SpawnConfig = .{},
    };
}

pub fn make(comptime lib: type, comptime config: Config(lib)) type {
    comptime {
        if (config.tick_interval_ns == 0) {
            @compileError("zux.pipeline.Pipeline.Config.tick_interval_ns must be > 0");
        }
    }

    return struct {
        const Self = @This();

        pub const MessageChannel = sync.Channel(lib.Channel)(Message);
        pub const Allocator = lib.mem.Allocator;
        pub const Worker = lib.Thread;
        pub const default_capacity: usize = 64;
        pub const default_poll_timeout_ns: u32 = 10 * 1000 * 1000;
        pub const pipeline_config = config;
        const BoolAtomic = lib.atomic.Value(bool);
        const PollerList = lib.ArrayList(PollWorker);
        const ReceiverList = lib.ArrayList(ReceiverBinding);

        pub const PollWorker = struct {
            thread: Worker,
        };

        pub const ReceiverBinding = struct {
            provider_ptr: *anyopaque,
            receiver: *EventReceiver,
            clearEventReceiver: *const fn (self: *anyopaque) void,

            pub fn init(provider_ptr: *anyopaque, receiver: *EventReceiver, clearEventReceiver: *const fn (self: *anyopaque) void) @This() {
                return .{
                    .provider_ptr = provider_ptr,
                    .receiver = receiver,
                    .clearEventReceiver = clearEventReceiver,
                };
            }

            pub fn deinit(self: @This()) void {
                self.clearEventReceiver(self.provider_ptr);
            }
        };

        allocator: Allocator,
        outbound: ?Emitter = null,
        inbox: MessageChannel,
        driver_thread: ?Worker = null,
        tick_thread: ?Worker = null,

        mu: lib.Thread.Mutex = .{},
        pollers: PollerList = .empty,
        receivers: ReceiverList = .empty,

        stopping: BoolAtomic = BoolAtomic.init(false),

        pub fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .outbound = null,
                .inbox = try MessageChannel.make(allocator, default_capacity),
            };
        }

        pub fn inject(self: *Self, message: Message) !void {
            const sent = try self.inbox.send(message);
            if (!sent.ok) return error.PipelineStopped;
        }

        pub fn emit(self: *Self, body: Message.Event) !void {
            return self.inject(.{
                .origin = .manual,
                .timestamp_ns = lib.time.nanoTimestamp(),
                .body = body,
            });
        }

        pub fn tick(self: *Self) !void {
            return self.emit(.{ .tick = .{} });
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.outbound = out;
        }

        pub fn pollFrom(self: *Self, comptime Source: type, source: *Source) !void {
            comptime {
                _ = @as(*const fn (*Source, ?u32) anyerror!Message.Event, &Source.poll);
            }

            self.mu.lock();
            defer self.mu.unlock();

            try self.pollers.ensureUnusedCapacity(self.allocator, 1);

            const thread = try Worker.spawn(config.spawn_config, struct {
                fn run(pipeline: *Self, src: *Source) void {
                    pipeline.pollLoop(Source, src) catch |err| Self.reportAsyncFailure("poll worker failed", err);
                }
            }.run, .{ self, source });

            self.pollers.appendAssumeCapacity(.{
                .thread = thread,
            });
        }

        pub fn hookOn(self: *Self, comptime Source: type, source: *Source) !void {
            comptime {
                _ = @as(*const fn (*Source, *const EventReceiver) void, &Source.setEventReceiver);
                _ = @as(*const fn (*Source) void, &Source.clearEventReceiver);
            }

            self.mu.lock();
            defer self.mu.unlock();

            try self.receivers.ensureUnusedCapacity(self.allocator, 1);
            const hook_fn = struct {
                fn emitFn(ctx: *anyopaque, body: Message.Event) void {
                    const p: *Self = @ptrCast(@alignCast(ctx));
                    p.inject(.{
                        .origin = .source,
                        .timestamp_ns = lib.time.nanoTimestamp(),
                        .body = body,
                    }) catch |err| {
                        if (!p.stopping.load(.acquire)) {
                            Self.reportAsyncFailure("hookOn inject failed", err);
                        }
                    };
                }

                fn clearEventReceiverFn(source_self: *anyopaque) void {
                    const source_ptr: *Source = @ptrCast(@alignCast(source_self));
                    source_ptr.clearEventReceiver();
                }
            };
            const receiver = try self.allocator.create(EventReceiver);
            receiver.* = EventReceiver.init(@ptrCast(self), hook_fn.emitFn);
            const reg = ReceiverBinding.init(@ptrCast(source), receiver, hook_fn.clearEventReceiverFn);
            source.setEventReceiver(reg.receiver);
            self.receivers.appendAssumeCapacity(reg);
        }

        pub fn start(self: *Self) !void {
            if (self.driver_thread != null or self.tick_thread != null) return;
            if (self.outbound == null) return error.OutputNotBound;
            self.driver_thread = try Worker.spawn(config.spawn_config, struct {
                fn run(pipeline: *Self) void {
                    pipeline.driveLoop() catch |err| Self.reportAsyncFailure("driver thread failed", err);
                }
            }.run, .{self});
            errdefer {
                self.stop();
                if (self.driver_thread) |thread| {
                    thread.join();
                    self.driver_thread = null;
                }
            }

            self.tick_thread = try Worker.spawn(config.spawn_config, struct {
                fn run(pipeline: *Self) void {
                    pipeline.tickLoop() catch |err| Self.reportAsyncFailure("tick thread failed", err);
                }
            }.run, .{self});
        }

        pub fn stop(self: *Self) void {
            self.stopping.store(true, .release);

            self.mu.lock();
            defer self.mu.unlock();
            for (self.receivers.items) |reg| {
                reg.deinit();
                self.allocator.destroy(reg.receiver);
            }
            self.receivers.clearRetainingCapacity();
            self.inbox.close();
        }

        pub fn wait(self: *Self) void {
            if (self.driver_thread) |thread| {
                thread.join();
                self.driver_thread = null;
            }

            if (self.tick_thread) |thread| {
                thread.join();
                self.tick_thread = null;
            }

            self.mu.lock();
            defer self.mu.unlock();
            for (self.pollers.items) |worker| {
                worker.thread.join();
            }
            self.pollers.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            lib.debug.assert(self.driver_thread == null);
            lib.debug.assert(self.tick_thread == null);
            lib.debug.assert(self.pollers.items.len == 0);
            lib.debug.assert(self.receivers.items.len == 0);
            self.pollers.deinit(self.allocator);
            self.receivers.deinit(self.allocator);
            self.inbox.deinit();
        }

        fn reportAsyncFailure(comptime label: []const u8, err: anyerror) noreturn {
            lib.debug.print("zux.pipeline.Pipeline {s}: {s}\n", .{ label, @errorName(err) });
            @panic("zux.pipeline.Pipeline background worker failed");
        }

        fn driveLoop(self: *Self) !void {
            while (!self.stopping.load(.acquire)) {
                const recv = try self.inbox.recv();
                if (!recv.ok) return;
                if (self.stopping.load(.acquire)) return;
                const out = self.outbound orelse return error.OutputNotBound;
                try out.emit(recv.value);
            }
        }

        fn tickLoop(self: *Self) !void {
            while (!self.stopping.load(.acquire)) {
                Worker.sleep(config.tick_interval_ns);
                if (self.stopping.load(.acquire)) return;

                self.tick() catch |err| {
                    if (self.stopping.load(.acquire)) return;
                    return err;
                };
            }
        }

        fn pollLoop(self: *Self, comptime Source: type, source: *Source) !void {
            while (!self.stopping.load(.acquire)) {
                const body = source.poll(default_poll_timeout_ns) catch |err| switch (err) {
                    error.Timeout => continue,
                    else => return err,
                };
                self.inject(.{
                    .origin = .source,
                    .timestamp_ns = lib.time.nanoTimestamp(),
                    .body = body,
                }) catch |err| {
                    if (self.stopping.load(.acquire)) return;
                    return err;
                };
            }
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const embed_std = @import("embed_std");
    const sync_mod = @import("sync");

    const HarnessLib = struct {
        pub const mem = embed_std.std.mem;
        pub const Thread = embed_std.std.Thread;
        pub const atomic = embed_std.std.atomic;
        pub const time = embed_std.std.time;
        pub const debug = embed_std.std.debug;
        pub const ArrayList = embed_std.std.ArrayList;
        pub const Channel = struct {
            fn factory(comptime T: type) type {
                const Wrapped = embed_std.sync.Channel(T);
                return struct {
                    inner: Wrapped,

                    pub fn init(allocator: embed_std.std.mem.Allocator, capacity: usize) !@This() {
                        return .{ .inner = try Wrapped.make(allocator, capacity) };
                    }

                    pub fn deinit(self: *@This()) void {
                        self.inner.deinit();
                    }

                    pub fn close(self: *@This()) void {
                        self.inner.close();
                    }

                    pub fn send(self: *@This(), value: T) !sync_mod.channel.SendResult() {
                        return self.inner.send(value);
                    }

                    pub fn sendTimeout(self: *@This(), value: T, timeout_ms: u32) !sync_mod.channel.SendResult() {
                        return self.inner.sendTimeout(value, timeout_ms);
                    }

                    pub fn recv(self: *@This()) !sync_mod.channel.RecvResult(T) {
                        return self.inner.recv();
                    }

                    pub fn recvTimeout(self: *@This(), timeout_ms: u32) !sync_mod.channel.RecvResult(T) {
                        return self.inner.recvTimeout(timeout_ms);
                    }
                };
            }
        }.factory;
    };

    const TestCase = struct {
        fn pollFromDrivesRootAndStopsCleanly(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{});
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                seen_count: AtomicU32 = AtomicU32.init(0),
                last_source_id: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !usize {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            _ = self.seen_count.fetchAdd(1, .acq_rel);
                            self.last_source_id.store(button.source_id, .release);
                            return 1;
                        },
                        else => return 0,
                    }
                }
            };

            const Source = struct {
                mu: HarnessLib.Thread.Mutex = .{},
                cv: HarnessLib.Thread.Condition = .{},
                pending: ?Message.Event = null,

                pub fn poll(self: *@This(), timeout_ns: ?u32) !Message.Event {
                    self.mu.lock();
                    defer self.mu.unlock();

                    while (self.pending == null) {
                        if (timeout_ns) |wait_ns| {
                            self.cv.timedWait(&self.mu, wait_ns) catch |err| switch (err) {
                                error.Timeout => return error.Timeout,
                            };
                        } else {
                            self.cv.wait(&self.mu);
                        }
                    }

                    const body = self.pending.?;
                    self.pending = null;
                    return body;
                }

                pub fn push(self: *@This(), body: Message.Event) void {
                    self.mu.lock();
                    self.pending = body;
                    self.cv.signal();
                    self.mu.unlock();
                }
            };

            var root_impl = RootImpl{};
            const root = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();
            pipeline.bindOutput(root.in);

            try pipeline.start();

            var source = Source{};
            try pipeline.pollFrom(Source, &source);
            source.push(.{
                .raw_single_button = .{
                    .source_id = 7,
                    .pressed = true,
                },
            });

            var attempts: usize = 0;
            while (attempts < 200 and root_impl.seen_count.load(.acquire) == 0) : (attempts += 1) {
                HarnessLib.Thread.sleep(HarnessLib.time.ns_per_ms);
            }

            try testing.expectEqual(@as(u32, 1), root_impl.seen_count.load(.acquire));
            try testing.expectEqual(@as(u32, 7), root_impl.last_source_id.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn startRequiresBoundOutput(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{});

            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();

            try testing.expectError(error.OutputNotBound, pipeline.start());
        }

        fn startEmitsTickMessages(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{
                .tick_interval_ns = HarnessLib.time.ns_per_ms,
            });
            const AtomicU32 = HarnessLib.atomic.Value(u32);
            const AtomicU8 = HarnessLib.atomic.Value(u8);

            const RootImpl = struct {
                tick_count: AtomicU32 = AtomicU32.init(0),
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.source)),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !usize {
                    switch (message.body) {
                        .tick => {
                            _ = self.tick_count.fetchAdd(1, .acq_rel);
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                            return 1;
                        },
                        else => return 0,
                    }
                }
            };

            var root_impl = RootImpl{};
            const root = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();
            pipeline.bindOutput(root.in);

            try pipeline.start();

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.tick_count.load(.acquire) == 0) : (attempts += 1) {
                HarnessLib.Thread.sleep(HarnessLib.time.ns_per_ms);
            }

            try testing.expect(root_impl.tick_count.load(.acquire) > 0);
            try testing.expectEqual(@intFromEnum(Message.Origin.manual), root_impl.last_origin.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn manualTickInjectsTickMessage(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{
                .tick_interval_ns = 100 * HarnessLib.time.ns_per_ms,
            });
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                tick_count: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !usize {
                    switch (message.body) {
                        .tick => {
                            _ = self.tick_count.fetchAdd(1, .acq_rel);
                            return 1;
                        },
                        else => return 0,
                    }
                }
            };

            var root_impl = RootImpl{};
            const root = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();
            pipeline.bindOutput(root.in);

            try pipeline.start();
            try pipeline.tick();

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.tick_count.load(.acquire) == 0) : (attempts += 1) {
                HarnessLib.Thread.sleep(HarnessLib.time.ns_per_ms);
            }

            try testing.expect(root_impl.tick_count.load(.acquire) > 0);

            pipeline.stop();
            pipeline.wait();
        }

        fn manualEmitWrapsBodyWithManualOrigin(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{
                .tick_interval_ns = 100 * HarnessLib.time.ns_per_ms,
            });
            const AtomicU8 = HarnessLib.atomic.Value(u8);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.source)),
                last_source_id: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !usize {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                            self.last_source_id.store(button.source_id, .release);
                            return 1;
                        },
                        else => return 0,
                    }
                }
            };

            var root_impl = RootImpl{};
            const root = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();
            pipeline.bindOutput(root.in);

            try pipeline.start();
            try pipeline.emit(.{
                .raw_single_button = .{
                    .source_id = 23,
                    .pressed = true,
                },
            });

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.last_source_id.load(.acquire) == 0) : (attempts += 1) {
                HarnessLib.Thread.sleep(HarnessLib.time.ns_per_ms);
            }

            try testing.expectEqual(@intFromEnum(Message.Origin.manual), root_impl.last_origin.load(.acquire));
            try testing.expectEqual(@as(u32, 23), root_impl.last_source_id.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn hookOnForwardsCallbackBodiesAndUnsetsReceiverOnStop(testing: anytype, allocator: lib.mem.Allocator) !void {
            const TestPipeline = make(HarnessLib, .{
                .tick_interval_ns = 100 * HarnessLib.time.ns_per_ms,
            });
            const AtomicU8 = HarnessLib.atomic.Value(u8);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                count: AtomicU32 = AtomicU32.init(0),
                last_source_id: AtomicU32 = AtomicU32.init(0),
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.manual)),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !usize {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            _ = self.count.fetchAdd(1, .acq_rel);
                            self.last_source_id.store(button.source_id, .release);
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                            return 1;
                        },
                        else => return 0,
                    }
                }
            };

            const Source = struct {
                receiver: ?*const EventReceiver = null,

                pub fn setEventReceiver(self: *@This(), receiver: *const EventReceiver) void {
                    self.receiver = receiver;
                }

                pub fn clearEventReceiver(self: *@This()) void {
                    self.receiver = null;
                }

                pub fn fire(self: *@This(), body: Message.Event) void {
                    if (self.receiver) |receiver| receiver.emit(body);
                }
            };

            var root_impl = RootImpl{};
            const root = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator);
            defer pipeline.deinit();
            pipeline.bindOutput(root.in);

            var source = Source{};
            try pipeline.hookOn(Source, &source);
            try pipeline.start();

            source.fire(.{
                .raw_single_button = .{
                    .source_id = 41,
                    .pressed = true,
                },
            });

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.count.load(.acquire) == 0) : (attempts += 1) {
                HarnessLib.Thread.sleep(HarnessLib.time.ns_per_ms);
            }

            try testing.expectEqual(@as(u32, 1), root_impl.count.load(.acquire));
            try testing.expectEqual(@as(u32, 41), root_impl.last_source_id.load(.acquire));
            try testing.expectEqual(@intFromEnum(Message.Origin.source), root_impl.last_origin.load(.acquire));

            pipeline.stop();
            try testing.expect(source.receiver == null);
            pipeline.wait();
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            inline for (.{
                TestCase.pollFromDrivesRootAndStopsCleanly,
                TestCase.startRequiresBoundOutput,
                TestCase.startEmitsTickMessages,
                TestCase.manualTickInjectsTickMessage,
                TestCase.manualEmitWrapsBodyWithManualOrigin,
                TestCase.hookOnForwardsCallbackBodiesAndUnsetsReceiverOnStop,
            }) |case| {
                case(testing, allocator) catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
