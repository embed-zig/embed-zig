const std = @import("std");
const yaml_case = @import("yaml_case.zig");
const remote_hal_mod = @import("remote_hal.zig");
const outbox_mod = @import("outbox.zig");

const RemoteHal = remote_hal_mod.RemoteHal;
const Outbox = outbox_mod.Outbox;
const DevRouter = outbox_mod.DevRouter;
const Step = yaml_case.Step;
const Track = yaml_case.Track;

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    error_msg: ?[]const u8 = null,
};

pub const TestSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
};

pub fn runTestDir(
    comptime hw: type,
    comptime firmware_entry: anytype,
    comptime SessionSetup: type,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !TestSummary {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    if (names.items.len == 0) {
        std.debug.print("[test] no YAML files found in {s}\n", .{dir_path});
        return .{ .total = 0, .passed = 0, .failed = 0 };
    }

    std.sort.heap([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const FileCtx = struct {
        result: TestResult,
        file_path: []const u8,
        allocator: std.mem.Allocator,
    };

    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);
    var ctxs = std.ArrayList(*FileCtx).empty;
    defer {
        for (ctxs.items) |c| allocator.destroy(c);
        ctxs.deinit(allocator);
    }

    for (names.items) |name| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        const ctx = try allocator.create(FileCtx);
        ctx.* = .{ .result = .{ .name = name, .passed = false }, .file_path = full_path, .allocator = allocator };
        try ctxs.append(allocator, ctx);

        const RunFn = *const fn (*FileCtx) void;
        const run_fn: RunFn = &struct {
            fn run(c: *FileCtx) void {
                runSingleTest(hw, firmware_entry, SessionSetup, c);
            }
        }.run;
        const t = try std.Thread.spawn(.{}, run_fn.*, .{ctx});
        try threads.append(allocator, t);
    }

    for (threads.items) |t| t.join();

    var passed: usize = 0;
    var failed: usize = 0;
    for (ctxs.items) |ctx| {
        if (ctx.result.passed) {
            std.debug.print("[PASS] {s}\n", .{ctx.result.name});
            passed += 1;
        } else {
            std.debug.print("[FAIL] {s}", .{ctx.result.name});
            if (ctx.result.error_msg) |msg| std.debug.print(": {s}", .{msg});
            std.debug.print("\n", .{});
            failed += 1;
        }
        allocator.free(ctx.file_path);
    }

    const total = passed + failed;
    std.debug.print("\n{} passed, {} failed, {} total\n", .{ passed, failed, total });
    return .{ .total = total, .passed = passed, .failed = failed };
}

const FwContext = struct {
    bus: *RemoteHal,
    running: *std.atomic.Value(bool),
    ready: std.atomic.Value(bool) = .{ .raw = false },
    done: std.atomic.Value(bool) = .{ .raw = false },
};

const TrackCtx = struct {
    steps: []const Step,
    outbox: *Outbox,
    bus: *RemoteHal,
    allocator: std.mem.Allocator,
    error_msg: ?[]const u8 = null,
    passed: bool = false,
};

fn runSingleTest(
    comptime hw: type,
    comptime firmware_entry: anytype,
    comptime SessionSetup: type,
    ctx: anytype,
) void {
    var test_case = yaml_case.loadFromFile(ctx.allocator, ctx.file_path) catch |err| {
        ctx.result.error_msg = @errorName(err);
        return;
    };
    defer test_case.deinit();

    const State = struct {
        running: std.atomic.Value(bool) = .{ .raw = true },
        router: DevRouter,
        bus: RemoteHal = undefined,
    };
    const state = ctx.allocator.create(State) catch {
        ctx.result.error_msg = "out of memory";
        return;
    };
    state.* = .{ .router = DevRouter.init(ctx.allocator) };
    state.bus = RemoteHal.initTest(&state.running, &state.router);

    for (test_case.tracks) |track| {
        _ = state.router.track(track.dev);
    }

    var fw_ctx = FwContext{ .bus = &state.bus, .running = &state.running };

    const RunFn = *const fn (*FwContext) void;
    const run_fn: RunFn = &struct {
        fn run(fc: *FwContext) void {
            var session_ctx = SessionSetup.setup(fc.bus, fc.running);
            SessionSetup.bind(&session_ctx, fc.bus);
            fc.ready.store(true, .release);
            firmware_entry(hw, .{});
            SessionSetup.teardown(&session_ctx);
            fc.done.store(true, .release);
        }
    }.run;

    const fw_thread = std.Thread.spawn(.{}, run_fn.*, .{&fw_ctx}) catch {
        ctx.result.error_msg = "failed to spawn firmware thread";
        return;
    };

    while (!fw_ctx.ready.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    defer {
        state.running.store(false, .release);
        var wait_count: usize = 0;
        while (!fw_ctx.done.load(.acquire) and wait_count < 20) : (wait_count += 1) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (fw_ctx.done.load(.acquire)) {
            fw_thread.join();
            state.router.deinit();
            ctx.allocator.destroy(state);
        } else {
            fw_thread.detach();
        }
    }

    var track_ctxs = std.ArrayList(*TrackCtx).empty;
    defer {
        for (track_ctxs.items) |tc| ctx.allocator.destroy(tc);
        track_ctxs.deinit(ctx.allocator);
    }
    var track_threads = std.ArrayList(std.Thread).empty;
    defer track_threads.deinit(ctx.allocator);

    for (test_case.tracks) |track| {
        const tc = ctx.allocator.create(TrackCtx) catch {
            ctx.result.error_msg = "out of memory";
            return;
        };
        tc.* = .{
            .steps = track.steps,
            .outbox = state.router.track(track.dev),
            .bus = &state.bus,
            .allocator = ctx.allocator,
        };
        track_ctxs.append(ctx.allocator, tc) catch {
            ctx.result.error_msg = "out of memory";
            return;
        };

        const t = std.Thread.spawn(.{}, runTrack, .{tc}) catch {
            ctx.result.error_msg = "failed to spawn track thread";
            return;
        };
        track_threads.append(ctx.allocator, t) catch {
            ctx.result.error_msg = "out of memory";
            return;
        };
    }

    for (track_threads.items) |t| t.join();

    for (track_ctxs.items) |tc| {
        if (!tc.passed) {
            ctx.result.error_msg = tc.error_msg orelse "track failed";
            return;
        }
    }

    ctx.result.passed = true;
}

fn runTrack(tc: *TrackCtx) void {
    for (tc.steps) |step| {
        switch (step.kind) {
            .send => {
                tc.bus.dispatchRaw(step.payload);
            },
            .wait => {
                const ms = std.fmt.parseInt(u64, step.payload, 10) catch {
                    tc.error_msg = "invalid wait value";
                    return;
                };
                std.Thread.sleep(ms * std.time.ns_per_ms);
            },
            .expect => {
                const msg = tc.outbox.pop(5000) orelse {
                    tc.error_msg = "timeout waiting for expected message";
                    return;
                };
                defer tc.allocator.free(msg);
                if (!jsonSubsetMatch(step.payload, msg)) {
                    tc.error_msg = "message mismatch";
                    return;
                }
            },
            .match_until => {
                const deadline_ms = @as(u64, @intCast(std.time.milliTimestamp())) + 10000;
                var count: usize = 0;
                var matched = false;

                while (true) {
                    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
                    if (now_ms >= deadline_ms) break;
                    const remaining: u32 = @intCast(deadline_ms - now_ms);
                    const msg = tc.outbox.pop(remaining) orelse break;
                    defer tc.allocator.free(msg);

                    count += 1;

                    if (jsonSubsetMatch(step.payload, msg)) {
                        matched = true;
                        break;
                    }
                }

                if (!matched) {
                    tc.error_msg = "match_until: target not reached";
                    return;
                }

                if (step.count) |expected_count| {
                    if (count != expected_count) {
                        tc.error_msg = "match_until: count mismatch";
                        return;
                    }
                }
            },
        }
    }

    tc.passed = true;
}

fn jsonSubsetMatch(expected_str: []const u8, actual_str: []const u8) bool {
    const expected = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, expected_str, .{}) catch return false;
    defer expected.deinit();
    const actual = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, actual_str, .{}) catch return false;
    defer actual.deinit();
    return jsonValueSubset(expected.value, actual.value);
}

fn jsonValueSubset(expected: std.json.Value, actual: std.json.Value) bool {
    switch (expected) {
        .object => |exp_obj| {
            switch (actual) {
                .object => |act_obj| {
                    var it = exp_obj.iterator();
                    while (it.next()) |entry| {
                        const act_val = act_obj.get(entry.key_ptr.*) orelse return false;
                        if (!jsonValueSubset(entry.value_ptr.*, act_val)) return false;
                    }
                    return true;
                },
                else => return false,
            }
        },
        .array => |exp_arr| {
            switch (actual) {
                .array => |act_arr| {
                    if (exp_arr.items.len != act_arr.items.len) return false;
                    for (exp_arr.items, act_arr.items) |e, a| {
                        if (!jsonValueSubset(e, a)) return false;
                    }
                    return true;
                },
                else => return false,
            }
        },
        .string => |exp_s| return switch (actual) {
            .string => |act_s| std.mem.eql(u8, exp_s, act_s),
            else => false,
        },
        .integer => |exp_i| return switch (actual) {
            .integer => |act_i| exp_i == act_i,
            else => false,
        },
        .float => |exp_f| return switch (actual) {
            .float => |act_f| @abs(exp_f - act_f) < 0.001,
            .integer => |act_i| @abs(exp_f - @as(f64, @floatFromInt(act_i))) < 0.001,
            else => false,
        },
        .bool => |exp_b| return switch (actual) {
            .bool => |act_b| exp_b == act_b,
            else => false,
        },
        .null => return actual == .null,
        .number_string => return false,
    }
}
