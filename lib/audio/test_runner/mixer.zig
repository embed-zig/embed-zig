//! mixer test runner — portable/default mixer contract checks.
//!
//! The current runner executes against the in-tree default backend. Portable
//! cases exercise contract-facing behavior on that reference backend, while
//! default-only cases remain grouped separately so the split stays visible.

const embed = @import("embed");
const testing_api = @import("testing");
const MixerMod = @import("../Mixer.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn run(comptime lib: type, allocator: lib.mem.Allocator) !void {
    try runImpl(lib, allocator);
}

fn runImpl(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const Suite = SuiteType(lib);
    try Suite.exec(allocator);
}

fn SuiteType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const Atomic = lib.atomic.Value;
    const testing = lib.testing;
    const DefaultMixerType = MixerMod.make(lib);
    const Track = MixerMod.Track;
    const CountingAllocator = CountingAllocatorType(lib);
    const run_log = lib.log.scoped(.audio_mixer_runner);

    return struct {
        fn exec(allocator: Allocator) !void {
            try runContractCasesOnDefaultBackend(allocator);
            try runDefaultCases(allocator);
        }

        // Portable rows currently execute against the default backend because it
        // is the only in-tree mixer implementation.
        fn runContractCasesOnDefaultBackend(allocator: Allocator) !void {
            try runCase("backpressure_blocks_until_read_progress", allocator, testBackpressureBlocksUntilReadProgress);
            try runCase("mixer_close_with_error_wakes_blocked_writer", allocator, testMixerCloseWithErrorWakesBlockedWriter);
            try runCase("concurrent_read_write_single_track", allocator, testConcurrentReadWriteSingleTrack);
            try runCase("concurrent_gain_updates_during_reads", allocator, testConcurrentGainUpdatesDuringReads);
            try runCase("native_steady_state_has_no_allocations", allocator, testNoHotPathAllocAfterSetup);
        }

        fn runDefaultCases(allocator: Allocator) !void {
            try runCase("multi_track_steady_state_has_no_alloc_growth", allocator, testMultiTrackSteadyStateNoAllocationGrowth);
        }

        fn runCase(
            comptime name: []const u8,
            allocator: Allocator,
            comptime case_fn: *const fn (Allocator) anyerror!void,
        ) !void {
            run_log.info("case={s}", .{name});
            try case_fn(allocator);
        }

        fn waitUntilTrue(flag: *Atomic(bool), comptime err_tag: anyerror) !void {
            var spins: usize = 0;
            while (!flag.load(.acquire)) : (spins += 1) {
                if (spins == 10_000) return err_tag;
                if (spins % 128 == 0) {
                    Thread.sleep(100_000);
                } else {
                    Thread.yield() catch {};
                }
            }
        }

        fn testBackpressureBlocksUntilReadProgress(allocator: Allocator) !void {
            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = 2 });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2 });

            const State = struct {
                track: Track,
                started: Atomic(bool) = Atomic(bool).init(false),
                finished: Atomic(bool) = Atomic(bool).init(false),
                result: ?anyerror = null,
            };

            var state = State{ .track = handle.track };

            const writer = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    s.started.store(true, .release);
                    s.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 3, 4 }) catch |err| {
                        s.result = err;
                        s.finished.store(true, .release);
                        return;
                    };
                    s.finished.store(true, .release);
                }
            }.run, .{&state});

            try waitUntilTrue(&state.started, error.WriterDidNotStart);

            for (0..1000) |_| {
                if (state.finished.load(.acquire)) break;
                Thread.yield() catch {};
            }
            try testing.expect(!state.finished.load(.acquire));

            var out: [4]i16 = undefined;
            const first = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
            try testing.expectEqual(@as(usize, 2), first);
            try testing.expectEqualSlices(i16, &.{ 1, 2 }, out[0..first]);

            writer.join();
            if (state.result) |err| return err;

            mixer.closeWrite();
            const second = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
            try testing.expectEqual(@as(usize, 2), second);
            try testing.expectEqualSlices(i16, &.{ 3, 4 }, out[0..second]);
            try testing.expectEqual(@as(?usize, null), mixer.read(&out));
        }

        fn testMixerCloseWithErrorWakesBlockedWriter(allocator: Allocator) !void {
            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = 2 });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2 });

            const State = struct {
                track: Track,
                started: Atomic(bool) = Atomic(bool).init(false),
                finished: Atomic(bool) = Atomic(bool).init(false),
                result: ?anyerror = null,
            };

            var state = State{ .track = handle.track };

            const writer = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    s.started.store(true, .release);
                    s.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 3, 4 }) catch |err| {
                        s.result = err;
                        s.finished.store(true, .release);
                        return;
                    };
                    s.finished.store(true, .release);
                }
            }.run, .{&state});

            try waitUntilTrue(&state.started, error.WriterDidNotStart);

            for (0..1000) |_| {
                if (state.finished.load(.acquire)) break;
                Thread.yield() catch {};
            }
            try testing.expect(!state.finished.load(.acquire));

            mixer.closeWithError();
            writer.join();

            try testing.expectEqual(true, state.finished.load(.acquire));
            try testing.expect(state.result != null);
            var post_close_err: ?anyerror = null;
            handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{5}) catch |err| {
                post_close_err = err;
            };
            try testing.expect(post_close_err != null);

            var out: [4]i16 = undefined;
            try testing.expectEqual(@as(?usize, null), mixer.read(&out));
        }

        fn testConcurrentReadWriteSingleTrack(allocator: Allocator) !void {
            const total_samples = 32;
            const chunk_len = 8;

            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = total_samples });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            const State = struct {
                track: Track,
                samples: [total_samples]i16,
                done: Atomic(bool) = Atomic(bool).init(false),
                result: ?anyerror = null,
            };

            var state = State{
                .track = handle.track,
                .samples = undefined,
            };
            for (&state.samples, 0..) |*sample, idx| {
                sample.* = @intCast(idx + 1);
            }

            const writer = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    var i: usize = 0;
                    while (i < s.samples.len) : (i += chunk_len) {
                        const upper = @min(i + chunk_len, s.samples.len);
                        s.track.write(.{ .rate = 8000, .channels = .mono }, s.samples[i..upper]) catch |err| {
                            s.result = err;
                            break;
                        };
                        Thread.yield() catch {};
                    }
                    s.done.store(true, .release);
                }
            }.run, .{&state});

            var collected: [total_samples]i16 = undefined;
            var collected_len: usize = 0;
            var close_requested = false;
            var out: [chunk_len]i16 = undefined;

            while (true) {
                if (state.done.load(.acquire) and !close_requested) {
                    mixer.closeWrite();
                    close_requested = true;
                }

                if (mixer.read(&out)) |n| {
                    if (n == 0) {
                        Thread.yield() catch {};
                        continue;
                    }
                    @memcpy(collected[collected_len .. collected_len + n], out[0..n]);
                    collected_len += n;
                    continue;
                }
                break;
            }

            writer.join();
            if (state.result) |err| return err;

            try testing.expectEqual(@as(usize, total_samples), collected_len);
            try testing.expectEqualSlices(i16, state.samples[0..], collected[0..collected_len]);
        }

        fn testConcurrentGainUpdatesDuringReads(allocator: Allocator) !void {
            const total_samples = 256;
            const out_chunk = 4;

            const mixer = try DefaultMixerType.init(.{
                .allocator = allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = total_samples });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            var input: [total_samples]i16 = undefined;
            @memset(&input, 100);
            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &input);

            const State = struct {
                mixer: MixerMod,
                mutex: Thread.Mutex = .{},
                cond: Thread.Condition = .{},
                started: bool = false,
                active: bool = false,
                draining: bool = false,
                finished: bool = false,
                reads_in_phase: usize = 0,
                target_reads: usize = 0,
                saw_zero: bool = false,
                saw_nonzero: bool = false,
                bad_sample: bool = false,
                seen: usize = 0,
            };

            var state = State{
                .mixer = mixer,
            };

            const reader = try Thread.spawn(.{}, struct {
                fn run(s: *State) void {
                    var out: [out_chunk]i16 = undefined;
                    s.mutex.lock();
                    s.started = true;
                    s.cond.broadcast();
                    s.mutex.unlock();
                    while (true) {
                        s.mutex.lock();
                        while (!s.active and !s.finished) s.cond.wait(&s.mutex);
                        const draining = s.draining;
                        const finished = s.finished;
                        s.mutex.unlock();
                        if (finished) return;

                        if (s.mixer.read(&out)) |n| {
                            if (n == 0) {
                                Thread.yield() catch {};
                                continue;
                            }
                            s.mutex.lock();
                            for (out[0..n]) |sample| {
                                if (sample == 0) {
                                    s.saw_zero = true;
                                } else {
                                    s.saw_nonzero = true;
                                }
                                if (sample < 0 or sample > 100) s.bad_sample = true;
                            }
                            s.seen += n;
                            if (!draining) {
                                s.reads_in_phase += 1;
                                if (s.reads_in_phase >= s.target_reads) {
                                    s.active = false;
                                    s.cond.broadcast();
                                }
                            }
                            s.mutex.unlock();
                            continue;
                        }
                        s.mutex.lock();
                        s.finished = true;
                        s.active = false;
                        s.cond.broadcast();
                        s.mutex.unlock();
                        break;
                    }
                }
            }.run, .{&state});

            state.mutex.lock();
            while (!state.started) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(1.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 4;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(0.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 12;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            handle.ctrl.setGain(1.0);
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 12;
            state.draining = false;
            state.active = true;
            state.cond.broadcast();
            while (state.active) state.cond.wait(&state.mutex);
            state.mutex.unlock();

            mixer.closeWrite();
            state.mutex.lock();
            state.reads_in_phase = 0;
            state.target_reads = 0;
            state.draining = true;
            state.active = true;
            state.cond.broadcast();
            while (!state.finished) state.cond.wait(&state.mutex);
            state.mutex.unlock();
            reader.join();

            try testing.expectEqual(@as(usize, total_samples), state.seen);
            try testing.expect(!state.bad_sample);
            try testing.expect(state.saw_zero);
            try testing.expect(state.saw_nonzero);
        }

        fn testNoHotPathAllocAfterSetup(allocator: Allocator) !void {
            var counting = CountingAllocator.init(allocator);
            const counted = counting.allocator();

            const mixer = try DefaultMixerType.init(.{
                .allocator = counted,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            const samples = [_]i16{ 1, 2, 3, 4 };
            const baseline = counting.snapshot();

            for (0..8) |_| {
                try handle.track.write(.{ .rate = 16000, .channels = .mono }, &samples);
                var out: [samples.len]i16 = undefined;
                const n = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
                try testing.expectEqual(samples.len, n);
                try testing.expectEqualSlices(i16, &samples, out[0..n]);
            }

            const after = counting.snapshot();
            try testing.expectEqual(baseline.alloc_count, after.alloc_count);
            try testing.expectEqual(baseline.resize_count, after.resize_count);
            try testing.expectEqual(baseline.remap_count, after.remap_count);
        }

        fn testMultiTrackSteadyStateNoAllocationGrowth(allocator: Allocator) !void {
            var counting = CountingAllocator.init(allocator);
            const counted = counting.allocator();

            const mixer = try DefaultMixerType.init(.{
                .allocator = counted,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const a = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer a.track.deinit();
            defer a.ctrl.deinit();
            const b = try mixer.createTrack(.{ .buffer_capacity = 8 });
            defer b.track.deinit();
            defer b.ctrl.deinit();

            const left = [_]i16{ 1, 1, 1, 1 };
            const right = [_]i16{ 2, 2, 2, 2 };
            const expected = [_]i16{ 3, 3, 3, 3 };
            const baseline = counting.snapshot();

            for (0..8) |_| {
                try a.track.write(.{ .rate = 16000, .channels = .mono }, &left);
                try b.track.write(.{ .rate = 16000, .channels = .mono }, &right);
                var out: [expected.len]i16 = undefined;
                const n = mixer.read(&out) orelse return error.UnexpectedTerminalRead;
                try testing.expectEqual(expected.len, n);
                try testing.expectEqualSlices(i16, &expected, out[0..n]);
            }

            const after = counting.snapshot();
            try testing.expectEqual(baseline.alloc_count, after.alloc_count);
            try testing.expectEqual(baseline.resize_count, after.resize_count);
            try testing.expectEqual(baseline.remap_count, after.remap_count);
        }
    };
}

fn allocatorAlignment(comptime lib: type) type {
    const alloc_ptr_type = @TypeOf(lib.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

fn CountingAllocatorType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Alignment = allocatorAlignment(lib);

    return struct {
        backing: Allocator,
        alloc_count: usize = 0,
        resize_count: usize = 0,
        remap_count: usize = 0,

        const Self = @This();

        const Snapshot = struct {
            alloc_count: usize,
            resize_count: usize,
            remap_count: usize,
        };

        pub fn init(backing: Allocator) Self {
            return .{ .backing = backing };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub fn snapshot(self: *Self) Snapshot {
            return .{
                .alloc_count = self.alloc_count,
                .resize_count = self.resize_count,
                .remap_count = self.remap_count,
            };
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.alloc_count += 1;
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.resize_count += 1;
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.remap_count += 1;
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}
