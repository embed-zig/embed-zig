const glib = @import("glib");
const EventReceiver = @import("../event.zig").EventReceiver;
const event = @import("../event.zig");
const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const Node = @import("Node.zig");

const pipeline_mod = @This();

pub fn Config(comptime grt: type) type {
    return struct {
        tick_interval: glib.time.duration.Duration = 10 * glib.time.duration.MilliSecond,
        spawn_config: grt.std.Thread.SpawnConfig = .{},
    };
}

pub fn make(comptime grt: type, comptime CustomEventRegistarType: type) type {
    return struct {
        const Self = @This();

        pub const Config = pipeline_mod.Config(grt);
        pub const CustomEventRegistar = CustomEventRegistarType;
        pub const MessageChannel = grt.sync.Channel(Message);
        pub const Allocator = glib.std.mem.Allocator;
        pub const Worker = grt.std.Thread;
        pub const default_capacity: usize = 64;
        pub const default_poll_timeout: glib.time.duration.Duration = 10 * glib.time.duration.MilliSecond;
        pub const default_config: Self.Config = .{};
        const BoolAtomic = grt.std.atomic.Value(bool);
        const PollerList = grt.std.ArrayList(PollWorker);
        const ReceiverList = grt.std.ArrayList(ReceiverBinding);

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
        config: Self.Config,
        custom_event_registar: CustomEventRegistar,
        outbound: ?Emitter = null,
        inbox: MessageChannel,
        driver_thread: ?Worker = null,
        tick_thread: ?Worker = null,

        mu: grt.std.Thread.Mutex = .{},
        pollers: PollerList = .empty,
        receivers: ReceiverList = .empty,

        stopping: BoolAtomic = BoolAtomic.init(false),
        tick_interval: glib.time.duration.Duration = default_config.tick_interval,
        tick_seq: u64 = 0,

        pub fn init(allocator: Allocator, config: Self.Config) !Self {
            if (config.tick_interval <= 0) return error.InvalidConfig;

            return .{
                .allocator = allocator,
                .config = config,
                .custom_event_registar = CustomEventRegistar.init(),
                .outbound = null,
                .inbox = try MessageChannel.make(allocator, default_capacity),
                .tick_interval = config.tick_interval,
            };
        }

        pub fn customEventRegistar(self: *Self) CustomEventRegistar {
            return self.custom_event_registar;
        }

        pub fn inject(self: *Self, message: Message) !void {
            const sent = self.inbox.send(message) catch |err| {
                message.deinit();
                return err;
            };
            if (!sent.ok) {
                message.deinit();
                return error.PipelineStopped;
            }
        }

        pub fn emit(self: *Self, body: Message.Event) !void {
            return self.inject(.{
                .origin = .manual,
                .timestamp = grt.time.instant.now(),
                .body = body,
            });
        }

        pub fn tick(self: *Self) !void {
            self.tick_seq +%= 1;
            return self.inject(.{
                .origin = .timer,
                .timestamp = grt.time.instant.now(),
                .body = .{ .tick = .{ .seq = self.tick_seq } },
            });
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.outbound = out;
        }

        pub fn pollFrom(self: *Self, comptime Source: type, source: *Source) !void {
            comptime {
                _ = @as(*const fn (*Source, ?glib.time.duration.Duration) anyerror!Message.Event, &Source.poll);
            }

            self.mu.lock();
            defer self.mu.unlock();

            try self.pollers.ensureUnusedCapacity(self.allocator, 1);

            const thread = try Worker.spawn(self.config.spawn_config, struct {
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
                        .timestamp = grt.time.instant.now(),
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
            self.driver_thread = try Worker.spawn(self.config.spawn_config, struct {
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

            self.tick_thread = try Worker.spawn(self.config.spawn_config, struct {
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
            grt.std.debug.assert(self.driver_thread == null);
            grt.std.debug.assert(self.tick_thread == null);
            grt.std.debug.assert(self.pollers.items.len == 0);
            grt.std.debug.assert(self.receivers.items.len == 0);
            self.pollers.deinit(self.allocator);
            self.receivers.deinit(self.allocator);
            self.inbox.deinit();
        }

        fn reportAsyncFailure(comptime label: []const u8, err: anyerror) noreturn {
            const run_log = grt.std.log.scoped(.zux_pipeline);
            run_log.err("{s}: {s}", .{ label, @errorName(err) });
            @panic("zux.pipeline.Pipeline background worker failed");
        }

        fn driveLoop(self: *Self) !void {
            while (true) {
                const recv = try self.inbox.recv();
                if (!recv.ok) return;
                const message = recv.value;
                defer message.deinit();
                if (self.stopping.load(.acquire)) continue;
                const out = self.outbound orelse return error.OutputNotBound;
                try out.emit(message);
            }
        }

        fn tickLoop(self: *Self) !void {
            while (!self.stopping.load(.acquire)) {
                grt.time.sleep(self.tick_interval);
                if (self.stopping.load(.acquire)) return;

                self.tick() catch |err| {
                    if (self.stopping.load(.acquire)) return;
                    return err;
                };
            }
        }

        fn pollLoop(self: *Self, comptime Source: type, source: *Source) !void {
            while (!self.stopping.load(.acquire)) {
                const body = source.poll(default_poll_timeout) catch |err| switch (err) {
                    error.Timeout => continue,
                    else => return err,
                };
                self.inject(.{
                    .origin = .source,
                    .timestamp = grt.time.instant.now(),
                    .body = body,
                }) catch |err| {
                    if (self.stopping.load(.acquire)) return;
                    return err;
                };
            }
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const HarnessLib = struct {
        pub const mem = grt.std.mem;
        pub const Thread = grt.std.Thread;
        pub const atomic = grt.std.atomic;
        pub const debug = grt.std.debug;
        pub const log = grt.std.log;
        pub const ArrayList = grt.std.ArrayList;
    };

    const TestCase = struct {
        fn pollFromDrivesRootAndStopsCleanly(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                seen_count: AtomicU32 = AtomicU32.init(0),
                last_source_id: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            _ = self.seen_count.fetchAdd(1, .acq_rel);
                            self.last_source_id.store(button.source_id, .release);
                        },
                        else => {},
                    }
                }
            };

            const Source = struct {
                mu: HarnessLib.Thread.Mutex = .{},
                cv: HarnessLib.Thread.Condition = .{},
                pending: ?Message.Event = null,

                pub fn poll(self: *@This(), timeout: ?glib.time.duration.Duration) !Message.Event {
                    self.mu.lock();
                    defer self.mu.unlock();

                    while (self.pending == null) {
                        if (timeout) |duration| {
                            if (duration <= 0) return error.Timeout;
                            self.cv.timedWait(&self.mu, @intCast(duration)) catch |err| switch (err) {
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
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{});
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

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
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expectEqual(@as(u32, 1), root_impl.seen_count.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 7), root_impl.last_source_id.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn startRequiresBoundOutput(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);

            var pipeline = try TestPipeline.init(allocator, .{});
            defer pipeline.deinit();

            try grt.std.testing.expectError(error.OutputNotBound, pipeline.start());
        }

        fn initRejectsNonPositiveTickInterval(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);

            try grt.std.testing.expectError(error.InvalidConfig, TestPipeline.init(allocator, .{
                .tick_interval = 0,
            }));
        }

        fn startEmitsTickMessages(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);
            const AtomicU32 = HarnessLib.atomic.Value(u32);
            const AtomicU8 = HarnessLib.atomic.Value(u8);

            const RootImpl = struct {
                tick_count: AtomicU32 = AtomicU32.init(0),
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.source)),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .tick => {
                            _ = self.tick_count.fetchAdd(1, .acq_rel);
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                        },
                        else => {},
                    }
                }
            };

            var root_impl = RootImpl{};
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{
                .tick_interval = grt.time.duration.MilliSecond,
            });
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

            try pipeline.start();

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.tick_count.load(.acquire) == 0) : (attempts += 1) {
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expect(root_impl.tick_count.load(.acquire) > 0);
            try grt.std.testing.expectEqual(@intFromEnum(Message.Origin.timer), root_impl.last_origin.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn manualTickInjectsTickMessage(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                tick_count: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .tick => {
                            _ = self.tick_count.fetchAdd(1, .acq_rel);
                        },
                        else => {},
                    }
                }
            };

            var root_impl = RootImpl{};
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{
                .tick_interval = 100 * grt.time.duration.MilliSecond,
            });
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

            try pipeline.start();
            try pipeline.tick();

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.tick_count.load(.acquire) == 0) : (attempts += 1) {
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expect(root_impl.tick_count.load(.acquire) > 0);

            pipeline.stop();
            pipeline.wait();
        }

        fn manualEmitWrapsBodyWithManualOrigin(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);
            const AtomicU8 = HarnessLib.atomic.Value(u8);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.source)),
                last_source_id: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                            self.last_source_id.store(button.source_id, .release);
                        },
                        else => {},
                    }
                }
            };

            var root_impl = RootImpl{};
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{
                .tick_interval = 100 * grt.time.duration.MilliSecond,
            });
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

            try pipeline.start();
            try pipeline.emit(.{
                .raw_single_button = .{
                    .source_id = 23,
                    .pressed = true,
                },
            });

            var attempts: usize = 0;
            while (attempts < 50 and root_impl.last_source_id.load(.acquire) == 0) : (attempts += 1) {
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expectEqual(@intFromEnum(Message.Origin.manual), root_impl.last_origin.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 23), root_impl.last_source_id.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }

        fn hookOnForwardsCallbackBodiesAndUnsetsReceiverOnStop(allocator: glib.std.mem.Allocator) !void {
            const TestPipeline = make(grt, event.CustomRegistar.Empty);
            const AtomicU8 = HarnessLib.atomic.Value(u8);
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const RootImpl = struct {
                count: AtomicU32 = AtomicU32.init(0),
                last_source_id: AtomicU32 = AtomicU32.init(0),
                last_origin: AtomicU8 = AtomicU8.init(@intFromEnum(Message.Origin.manual)),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .raw_single_button => |button| {
                            _ = self.count.fetchAdd(1, .acq_rel);
                            self.last_source_id.store(button.source_id, .release);
                            self.last_origin.store(@intFromEnum(message.origin), .release);
                        },
                        else => {},
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
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{
                .tick_interval = 100 * grt.time.duration.MilliSecond,
            });
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

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
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expectEqual(@as(u32, 1), root_impl.count.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 41), root_impl.last_source_id.load(.acquire));
            try grt.std.testing.expectEqual(@intFromEnum(Message.Origin.source), root_impl.last_origin.load(.acquire));

            pipeline.stop();
            try grt.std.testing.expect(source.receiver == null);
            pipeline.wait();
        }

        fn customEventPayloadIsDestroyedAfterDispatch(allocator: glib.std.mem.Allocator) !void {
            const CustomRegistar = @import("../event.zig").CustomRegistar;
            const AtomicU32 = HarnessLib.atomic.Value(u32);

            const Payload = struct {
                pub const event_name = "pipeline.payload";

                allocator: glib.std.mem.Allocator,
                deinit_count: *AtomicU32,
                value: u32,

                pub fn decodeJson(mem_allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
                    _ = mem_allocator;
                    _ = value;
                    unreachable;
                }

                pub fn deinit(self: *@This()) void {
                    _ = self.deinit_count.fetchAdd(1, .acq_rel);
                    self.allocator.destroy(self);
                }
            };
            const Registar = CustomRegistar.make(.{Payload});
            const TestPipeline = make(grt, Registar);

            const RootImpl = struct {
                seen_count: AtomicU32 = AtomicU32.init(0),
                last_source_id: AtomicU32 = AtomicU32.init(0),
                last_value: AtomicU32 = AtomicU32.init(0),

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), message: Message) !void {
                    switch (message.body) {
                        .custom => |custom| {
                            const payload = try custom.as(Payload);
                            _ = self.seen_count.fetchAdd(1, .acq_rel);
                            self.last_source_id.store(custom.source_id, .release);
                            self.last_value.store(payload.value, .release);
                        },
                        else => {},
                    }
                }
            };

            var deinit_count = AtomicU32.init(0);
            const payload = try allocator.create(Payload);
            payload.* = .{
                .allocator = allocator,
                .deinit_count = &deinit_count,
                .value = 123,
            };

            var root_impl = RootImpl{};
            const root_node = Node.init(RootImpl, &root_impl);
            var pipeline = try TestPipeline.init(allocator, .{
                .tick_interval = 100 * grt.time.duration.MilliSecond,
            });
            defer pipeline.deinit();
            pipeline.bindOutput(root_node.in);

            try pipeline.start();
            try pipeline.emit(.{
                .custom = Registar.init().initEvent(Payload, 91, payload),
            });

            var attempts: usize = 0;
            while (attempts < 200 and (root_impl.seen_count.load(.acquire) == 0 or deinit_count.load(.acquire) == 0)) : (attempts += 1) {
                grt.time.sleep(grt.time.duration.MilliSecond);
            }

            try grt.std.testing.expectEqual(@as(u32, 1), root_impl.seen_count.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 91), root_impl.last_source_id.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 123), root_impl.last_value.load(.acquire));
            try grt.std.testing.expectEqual(@as(u32, 1), deinit_count.load(.acquire));

            pipeline.stop();
            pipeline.wait();
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            inline for (.{
                TestCase.pollFromDrivesRootAndStopsCleanly,
                TestCase.startRequiresBoundOutput,
                TestCase.initRejectsNonPositiveTickInterval,
                TestCase.startEmitsTickMessages,
                TestCase.manualTickInjectsTickMessage,
                TestCase.manualEmitWrapsBodyWithManualOrigin,
                TestCase.hookOnForwardsCallbackBodiesAndUnsetsReceiverOnStop,
                TestCase.customEventPayloadIsDestroyedAfterDispatch,
            }) |case| {
                case(allocator) catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
