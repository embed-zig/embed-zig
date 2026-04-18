const embed = @import("embed");
const testing_mod = @import("testing");
const context_root = @import("context");
const BindingLink = context_root.Context.BindingLink;

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("cancel_fires_bound_fd_and_propagates", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelFiresBoundFdAndPropagatesCase(lib, case_allocator);
                }
            }.run));
            t.run("canceled_context_fires_immediately", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try canceledContextFiresImmediatelyCase(lib, case_allocator);
                }
            }.run));
            t.run("binding_deinit_stops_future_wakeups", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try bindingDeinitStopsFutureWakeupsCase(lib, case_allocator);
                }
            }.run));
            t.run("bind_link_null_deactivates_binding", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try bindLinkNullDeactivatesBindingCase(lib, case_allocator);
                }
            }.run));
            t.run("second_bind_returns_already_bound", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try secondBindReturnsAlreadyBoundCase(lib, case_allocator);
                }
            }.run));
            t.run("deinit_detaches_binding_before_parent_cancel", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deinitDetachesBindingBeforeParentCancelCase(lib, case_allocator);
                }
            }.run));
            t.run("context_deinit_deactivates_binding", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try contextDeinitDeactivatesBindingCase(lib, case_allocator);
                }
            }.run));
            t.run("bound_fd_wakes_before_child_binding_runs", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try boundFdWakesBeforeChildBindingRunsCase(lib, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn cancelFiresBoundFdAndPropagatesCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake = try initWakeSockets(lib);
    defer lib.posix.close(wake.send_fd);
    defer lib.posix.close(wake.recv_fd);

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    try parent.bindFd(lib, &wake.send_fd);

    try expectFdNotReadable(lib, wake.recv_fd);
    parent.cancelWithCause(error.BrokenPipe);

    try expectFdReadable(lib, wake.recv_fd);
    const child_err = child.err() orelse return error.BindFdCancelShouldPropagateToChild;
    if (child_err != error.BrokenPipe) return error.BindFdCancelChildWrongCause;
}

fn canceledContextFiresImmediatelyCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake = try initWakeSockets(lib);
    defer lib.posix.close(wake.send_fd);
    defer lib.posix.close(wake.recv_fd);

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();
    ctx.cancelWithCause(error.ConnectionReset);

    try ctx.bindFd(lib, &wake.send_fd);

    try expectFdReadable(lib, wake.recv_fd);
}

fn bindingDeinitStopsFutureWakeupsCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake = try initWakeSockets(lib);
    defer lib.posix.close(wake.send_fd);
    defer lib.posix.close(wake.recv_fd);

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();

    try ctx.bindFd(lib, &wake.send_fd);
    try ctx.bindLink(null);

    ctx.cancelWithCause(error.BrokenPipe);
    try expectFdNotReadable(lib, wake.recv_fd);
}

fn bindLinkNullDeactivatesBindingCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();

    var state = BindingState{};
    try ctx.bindLink(makeBindingLink(&state));
    try ctx.bindLink(null);

    if (state.fire_hits != 0) return error.BindLinkNullShouldNotFireBinding;
    if (state.deactivate_hits != 1) return error.BindLinkNullShouldDeactivateBinding;
}

fn secondBindReturnsAlreadyBoundCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake_a = try initWakeSockets(lib);
    defer lib.posix.close(wake_a.send_fd);
    defer lib.posix.close(wake_a.recv_fd);

    var wake_b = try initWakeSockets(lib);
    defer lib.posix.close(wake_b.send_fd);
    defer lib.posix.close(wake_b.recv_fd);

    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withCancel(bg);
    defer ctx.deinit();

    try ctx.bindFd(lib, &wake_a.send_fd);

    _ = ctx.bindFd(lib, &wake_b.send_fd) catch |err| {
        if (err == error.AlreadyBound) return;
        return err;
    };
    return error.ExpectedAlreadyBound;
}

fn deinitDetachesBindingBeforeParentCancelCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake = try initWakeSockets(lib);
    defer lib.posix.close(wake.send_fd);
    defer lib.posix.close(wake.recv_fd);

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var ctx = try ctx_ns.withCancel(parent);
    try ctx.bindFd(lib, &wake.send_fd);

    ctx.deinit();
    parent.cancelWithCause(error.BrokenPipe);
    try expectFdNotReadable(lib, wake.recv_fd);
}

fn contextDeinitDeactivatesBindingCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var ctx = try ctx_ns.withCancel(parent);

    var state = BindingState{};
    try ctx.bindLink(makeBindingLink(&state));

    ctx.deinit();
    parent.cancelWithCause(error.BrokenPipe);

    if (state.fire_hits != 0) return error.ContextDeinitShouldClearBinding;
    if (state.deactivate_hits != 1) return error.ContextDeinitShouldDeactivateBinding;
}

fn boundFdWakesBeforeChildBindingRunsCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var wake = try initWakeSockets(lib);
    defer lib.posix.close(wake.send_fd);
    defer lib.posix.close(wake.recv_fd);

    const State = struct {
        recv_fd: lib.posix.socket_t,
        readable_during_fire: bool = false,
    };

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    try parent.bindFd(lib, &wake.send_fd);
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
                    typed_state.readable_during_fire = pollReadable(lib, typed_state.recv_fd, 20) catch false;
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

fn initWakeSockets(comptime lib: type) !struct {
    recv_fd: lib.posix.socket_t,
    send_fd: lib.posix.socket_t,
} {
    const posix = lib.posix;
    const loopback_addr = [4]u8{ 127, 0, 0, 1 };
    const loopback_addr_u32 = @as(*align(1) const u32, @ptrCast(&loopback_addr)).*;

    const recv_fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    errdefer posix.close(recv_fd);

    var recv_storage: posix.sockaddr.storage = undefined;
    zeroStorage(lib, &recv_storage);
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
    zeroStorage(lib, &send_storage);
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

fn zeroStorage(comptime lib: type, storage: *lib.posix.sockaddr.storage) void {
    const bytes: *[@sizeOf(lib.posix.sockaddr.storage)]u8 = @ptrCast(storage);
    @memset(bytes, 0);
}

fn expectFdReadable(comptime lib: type, fd: lib.posix.socket_t) !void {
    const ready = try pollReadable(lib, fd, 20);
    if (!ready) return error.ExpectedReadableFd;
}

fn expectFdNotReadable(comptime lib: type, fd: lib.posix.socket_t) !void {
    const ready = try pollReadable(lib, fd, 0);
    if (ready) return error.ExpectedUnreadableFd;
}

fn pollReadable(comptime lib: type, fd: lib.posix.socket_t, timeout_ms: i32) !bool {
    var poll_fds = [_]lib.posix.pollfd{.{
        .fd = fd,
        .events = lib.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try lib.posix.poll(poll_fds[0..], timeout_ms);
    if (ready == 0) return false;
    if (poll_fds[0].revents == 0) return false;
    return true;
}
