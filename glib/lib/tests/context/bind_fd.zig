const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const time_mod = @import("time");
const BindingLink = context_root.Context.BindingLink;

pub fn make(comptime std: type, comptime time: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("cancel_fires_bound_fd_and_propagates", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelFiresBoundFdAndPropagatesCase(std, time, case_allocator);
                }
            }.run));
            t.run("canceled_context_fires_immediately", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try canceledContextFiresImmediatelyCase(std, time, case_allocator);
                }
            }.run));
            t.run("binding_deinit_stops_future_wakeups", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try bindingDeinitStopsFutureWakeupsCase(std, time, case_allocator);
                }
            }.run));
            t.run("bind_link_null_deactivates_binding", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try bindLinkNullDeactivatesBindingCase(std, time, case_allocator);
                }
            }.run));
            t.run("second_bind_returns_already_bound", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try secondBindReturnsAlreadyBoundCase(std, time, case_allocator);
                }
            }.run));
            t.run("deinit_detaches_binding_before_parent_cancel", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try deinitDetachesBindingBeforeParentCancelCase(std, time, case_allocator);
                }
            }.run));
            t.run("context_deinit_deactivates_binding", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try contextDeinitDeactivatesBindingCase(std, time, case_allocator);
                }
            }.run));
            t.run("bound_fd_wakes_before_child_binding_runs", testing_mod.TestRunner.fromFn(std, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try boundFdWakesBeforeChildBindingRunsCase(std, time, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn cancelFiresBoundFdAndPropagatesCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake = try initWakeSockets(std);
    defer std.posix.close(wake.send_fd);
    defer std.posix.close(wake.recv_fd);

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_api.withCancel(parent);
    defer child.deinit();
    try parent.bindFd(std, &wake.send_fd);

    try expectFdNotReadable(std, wake.recv_fd);
    parent.cancelWithCause(error.BrokenPipe);

    try expectFdReadable(std, wake.recv_fd);
    const child_err = child.err() orelse return error.BindFdCancelShouldPropagateToChild;
    if (child_err != error.BrokenPipe) return error.BindFdCancelChildWrongCause;
}

fn canceledContextFiresImmediatelyCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake = try initWakeSockets(std);
    defer std.posix.close(wake.send_fd);
    defer std.posix.close(wake.recv_fd);

    const bg = ctx_api.background();
    var ctx = try ctx_api.withCancel(bg);
    defer ctx.deinit();
    ctx.cancelWithCause(error.ConnectionReset);

    try ctx.bindFd(std, &wake.send_fd);

    try expectFdReadable(std, wake.recv_fd);
}

fn bindingDeinitStopsFutureWakeupsCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake = try initWakeSockets(std);
    defer std.posix.close(wake.send_fd);
    defer std.posix.close(wake.recv_fd);

    const bg = ctx_api.background();
    var ctx = try ctx_api.withCancel(bg);
    defer ctx.deinit();

    try ctx.bindFd(std, &wake.send_fd);
    try ctx.bindLink(null);

    ctx.cancelWithCause(error.BrokenPipe);
    try expectFdNotReadable(std, wake.recv_fd);
}

fn bindLinkNullDeactivatesBindingCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var ctx = try ctx_api.withCancel(bg);
    defer ctx.deinit();

    var state = BindingState{};
    try ctx.bindLink(makeBindingLink(&state));
    try ctx.bindLink(null);

    if (state.fire_hits != 0) return error.BindLinkNullShouldNotFireBinding;
    if (state.deactivate_hits != 1) return error.BindLinkNullShouldDeactivateBinding;
}

fn secondBindReturnsAlreadyBoundCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake_a = try initWakeSockets(std);
    defer std.posix.close(wake_a.send_fd);
    defer std.posix.close(wake_a.recv_fd);

    var wake_b = try initWakeSockets(std);
    defer std.posix.close(wake_b.send_fd);
    defer std.posix.close(wake_b.recv_fd);

    const bg = ctx_api.background();
    var ctx = try ctx_api.withCancel(bg);
    defer ctx.deinit();

    try ctx.bindFd(std, &wake_a.send_fd);

    _ = ctx.bindFd(std, &wake_b.send_fd) catch |err| {
        if (err == error.AlreadyBound) return;
        return err;
    };
    return error.ExpectedAlreadyBound;
}

fn deinitDetachesBindingBeforeParentCancelCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake = try initWakeSockets(std);
    defer std.posix.close(wake.send_fd);
    defer std.posix.close(wake.recv_fd);

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var ctx = try ctx_api.withCancel(parent);
    try ctx.bindFd(std, &wake.send_fd);

    ctx.deinit();
    parent.cancelWithCause(error.BrokenPipe);
    try expectFdNotReadable(std, wake.recv_fd);
}

fn contextDeinitDeactivatesBindingCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var ctx = try ctx_api.withCancel(parent);

    var state = BindingState{};
    try ctx.bindLink(makeBindingLink(&state));

    ctx.deinit();
    parent.cancelWithCause(error.BrokenPipe);

    if (state.fire_hits != 0) return error.ContextDeinitShouldClearBinding;
    if (state.deactivate_hits != 1) return error.ContextDeinitShouldDeactivateBinding;
}

fn boundFdWakesBeforeChildBindingRunsCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    var wake = try initWakeSockets(std);
    defer std.posix.close(wake.send_fd);
    defer std.posix.close(wake.recv_fd);

    const State = struct {
        recv_fd: std.posix.socket_t,
        readable_during_fire: bool = false,
    };

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_api.withCancel(parent);
    defer child.deinit();
    try parent.bindFd(std, &wake.send_fd);
    var state = State{
        .recv_fd = wake.recv_fd,
    };
    const child_binding = struct {
        fn makeLink(link_state: *State) BindingLink {
            const gen = struct {
                fn fireFn(ptr: *anyopaque, cause: anyerror) void {
                    const same_cause = cause == error.BrokenPipe;
                    _ = same_cause;
                    const typed_state: *State = @ptrCast(@alignCast(ptr));
                    typed_state.readable_during_fire = pollReadable(std, typed_state.recv_fd, 20 * time_mod.duration.MilliSecond) catch false;
                }

                fn deactivateFn(ptr: *anyopaque) void {
                    _ = ptr;
                }

                const vtable = BindingLink.VTable{
                    .fireFn = fireFn,
                    .deactivateFn = deactivateFn,
                };
            };

            return .{
                .ptr = @ptrCast(link_state),
                .vtable = &gen.vtable,
            };
        }
    }.makeLink(&state);
    try child.bindLink(child_binding);

    parent.cancelWithCause(error.BrokenPipe);

    if (!state.readable_during_fire) return error.BindFdShouldWakeBeforeChildBinding;
    const child_err = child.err() orelse return error.BindFdChildBindingShouldCancel;
    if (child_err != error.BrokenPipe) return error.BindFdChildBindingWrongCause;
}

const BindingState = struct {
    fire_hits: usize = 0,
    deactivate_hits: usize = 0,
};

fn makeBindingLink(state: *BindingState) BindingLink {
    const gen = struct {
        fn fireFn(ptr: *anyopaque, cause: anyerror) void {
            const same_cause = cause == error.BrokenPipe;
            _ = same_cause;
            const typed_state: *BindingState = @ptrCast(@alignCast(ptr));
            typed_state.fire_hits += 1;
        }

        fn deactivateFn(ptr: *anyopaque) void {
            const typed_state: *BindingState = @ptrCast(@alignCast(ptr));
            typed_state.deactivate_hits += 1;
        }

        const vtable = BindingLink.VTable{
            .fireFn = fireFn,
            .deactivateFn = deactivateFn,
        };
    };

    return .{
        .ptr = @ptrCast(state),
        .vtable = &gen.vtable,
    };
}

fn initWakeSockets(comptime std: type) !struct {
    recv_fd: std.posix.socket_t,
    send_fd: std.posix.socket_t,
} {
    const posix = std.posix;
    const loopback_addr = [4]u8{ 127, 0, 0, 1 };
    const loopback_addr_u32 = @as(*align(1) const u32, @ptrCast(&loopback_addr)).*;

    const recv_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    errdefer posix.close(recv_fd);

    var recv_storage: posix.sockaddr.storage = undefined;
    zeroStorage(std, &recv_storage);
    const recv_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&recv_storage));
    recv_addr.* = .{
        .port = 0,
        .addr = loopback_addr_u32,
    };
    try posix.bind(recv_fd, @ptrCast(&recv_storage), @sizeOf(posix.sockaddr.in));

    var bound_addr: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(recv_fd, @ptrCast(&bound_addr), &bound_len);

    const send_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    errdefer posix.close(send_fd);

    var send_storage: posix.sockaddr.storage = undefined;
    zeroStorage(std, &send_storage);
    const send_addr: *posix.sockaddr.in = @ptrCast(@alignCast(&send_storage));
    send_addr.* = .{
        .port = bound_addr.port,
        .addr = loopback_addr_u32,
    };
    try posix.connect(send_fd, @ptrCast(&send_storage), @sizeOf(posix.sockaddr.in));

    return .{
        .recv_fd = recv_fd,
        .send_fd = send_fd,
    };
}

fn zeroStorage(comptime std: type, storage: *std.posix.sockaddr.storage) void {
    const bytes: *[@sizeOf(std.posix.sockaddr.storage)]u8 = @ptrCast(storage);
    @memset(bytes, 0);
}

fn expectFdReadable(comptime std: type, fd: std.posix.socket_t) !void {
    const ready = try pollReadable(std, fd, 20 * time_mod.duration.MilliSecond);
    if (!ready) return error.ExpectedReadableFd;
}

fn expectFdNotReadable(comptime std: type, fd: std.posix.socket_t) !void {
    const ready = try pollReadable(std, fd, 0);
    if (ready) return error.ExpectedUnreadableFd;
}

fn pollReadable(comptime std: type, fd: std.posix.socket_t, timeout: time_mod.duration.Duration) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(poll_fds[0..], posixPollTimeout(std, timeout));
    if (ready == 0) return false;
    if (poll_fds[0].revents == 0) return false;
    return true;
}

fn posixPollTimeout(comptime std: type, timeout: time_mod.duration.Duration) i32 {
    if (timeout <= 0) return 0;
    const ceil_ms = @divFloor(timeout - 1, time_mod.duration.MilliSecond) + 1;
    return @intCast(@min(ceil_ms, std.math.maxInt(i32)));
}
