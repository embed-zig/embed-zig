//! Std-backed Thread impl.

const builtin = @import("builtin");
const std = @import("std");
const glib = @import("glib");

const posix = std.posix;
const windows = std.os.windows;

handle: std.Thread,

const Self = @This();
const native_os = builtin.os.tag;
const std_max_name_len = std.Thread.max_name_len;
const contract_max_name_len = 128;

// Zig 0.15 does not expose Linux _SC_THREAD_STACK_MIN in std.c._SC. Both glibc
// and musl use this sysconf id, and pthreads rejects stacks below its value.
const linux_sc_thread_stack_min: c_int = 75;
pub const default_stack_size = std.Thread.SpawnConfig.default_stack_size;

pub const Id = std.Thread.Id;
pub const max_name_len = if (std_max_name_len == 0) 1 else @min(std_max_name_len, contract_max_name_len);

pub const Mutex = @import("Thread/Mutex.zig");
pub const Condition = @import("Thread/Condition.zig");
pub const RwLock = @import("Thread/RwLock.zig");

pub fn spawn(config: glib.std.Thread.SpawnConfig, comptime f: anytype, args: anytype) glib.std.Thread.SpawnError!Self {
    var spawn_config = config;
    if (spawn_config.stack_size == 0) {
        spawn_config.stack_size = default_stack_size;
    }
    spawn_config.stack_size = normalizeStackSize(spawn_config.stack_size);

    const handle = try std.Thread.spawn(.{
        .stack_size = spawn_config.stack_size,
        .allocator = spawn_config.allocator,
    }, f, args);
    return .{ .handle = handle };
}

fn normalizeStackSize(stack_size: usize) usize {
    if (comptime native_os == .linux and std.Thread.use_pthreads) {
        const min = std.c.sysconf(linux_sc_thread_stack_min);
        if (min <= 0) return stack_size;
        const pthread_stack_min: usize = @intCast(min);
        return @max(stack_size, pthread_stack_min);
    }
    return stack_size;
}

pub fn join(self: Self) void {
    self.handle.join();
}

pub fn detach(self: Self) void {
    self.handle.detach();
}

pub fn yield() glib.std.Thread.YieldError!void {
    return try std.Thread.yield();
}

pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn getCpuCount() glib.std.Thread.CpuCountError!usize {
    return try std.Thread.getCpuCount();
}

pub fn getCurrentId() Id {
    return std.Thread.getCurrentId();
}

pub fn setName(name: []const u8) glib.std.Thread.SetNameError!void {
    if (std_max_name_len == 0) return error.Unsupported;
    if (name.len > max_name_len) return error.NameTooLong;

    const name_with_terminator = blk: {
        var name_buf: [max_name_len:0]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        break :blk name_buf[0..name.len :0];
    };

    switch (native_os) {
        .linux => if (std.Thread.use_pthreads) {
            const err = try posix.prctl(.SET_NAME, .{@intFromPtr(name_with_terminator.ptr)});
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return,
                else => |e| return posix.unexpectedErrno(e),
            }
        } else {
            var buf: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "/proc/self/task/{d}/comm", .{std.Thread.getCurrentId()});
            const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
            defer file.close();
            try file.deprecatedWriter().writeAll(name);
            return;
        },
        .windows => {
            var buf: [max_name_len]u16 = undefined;
            const len = try std.unicode.wtf8ToWtf16Le(&buf, name);
            const byte_len = std.math.cast(u16, len * 2) orelse return error.NameTooLong;
            const unicode_string = windows.UNICODE_STRING{
                .Length = byte_len,
                .MaximumLength = byte_len,
                .Buffer = &buf,
            };

            switch (windows.ntdll.NtSetInformationThread(
                windows.GetCurrentThread(),
                .ThreadNameInformation,
                &unicode_string,
                @sizeOf(windows.UNICODE_STRING),
            )) {
                .SUCCESS => return,
                .NOT_IMPLEMENTED => return error.Unsupported,
                else => |err| return windows.unexpectedStatus(err),
            }
        },
        .macos, .ios, .watchos, .tvos, .visionos => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_setname_np(name_with_terminator.ptr);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .serenity => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_setname_np(std.c.pthread_self(), name_with_terminator.ptr);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return,
                .NAMETOOLONG => unreachable,
                .SRCH => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .netbsd, .solaris, .illumos => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_setname_np(std.c.pthread_self(), name_with_terminator.ptr, null);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return,
                .INVAL => unreachable,
                .SRCH => unreachable,
                .NOMEM => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .freebsd, .openbsd => if (std.Thread.use_pthreads) {
            std.c.pthread_set_name_np(std.c.pthread_self(), name_with_terminator.ptr);
            return;
        },
        .dragonfly => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_setname_np(std.c.pthread_self(), name_with_terminator.ptr);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .NAMETOOLONG => unreachable,
                .SRCH => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        else => {},
    }

    return error.Unsupported;
}

pub fn getName(buffer_ptr: *[max_name_len:0]u8) glib.std.Thread.GetNameError!?[]const u8 {
    if (std_max_name_len == 0) return error.Unsupported;

    buffer_ptr[max_name_len] = 0;
    var buffer: [:0]u8 = buffer_ptr;

    switch (native_os) {
        .linux => if (std.Thread.use_pthreads) {
            const err = try posix.prctl(.GET_NAME, .{@intFromPtr(buffer.ptr)});
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return std.mem.sliceTo(buffer, 0),
                else => |e| return posix.unexpectedErrno(e),
            }
        } else {
            var buf: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "/proc/self/task/{d}/comm", .{std.Thread.getCurrentId()});
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const data_len = try file.deprecatedReader().readAll(buffer_ptr[0 .. max_name_len + 1]);
            return if (data_len >= 1) buffer[0 .. data_len - 1] else null;
        },
        .windows => {
            const buf_capacity = @sizeOf(windows.UNICODE_STRING) + (@sizeOf(u16) * max_name_len);
            var buf: [buf_capacity]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;

            switch (windows.ntdll.NtQueryInformationThread(
                windows.GetCurrentThread(),
                .ThreadNameInformation,
                &buf,
                buf_capacity,
                null,
            )) {
                .SUCCESS => {
                    const string = @as(*const windows.UNICODE_STRING, @ptrCast(&buf));
                    const len = std.unicode.wtf16LeToWtf8(buffer, string.Buffer.?[0 .. string.Length / 2]);
                    return if (len > 0) buffer[0..len] else null;
                },
                .NOT_IMPLEMENTED => return error.Unsupported,
                else => |err| return windows.unexpectedStatus(err),
            }
        },
        .macos, .ios, .watchos, .tvos, .visionos => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_getname_np(std.c.pthread_self(), buffer.ptr, max_name_len + 1);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return std.mem.sliceTo(buffer, 0),
                .SRCH => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .serenity => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_getname_np(std.c.pthread_self(), buffer.ptr, max_name_len + 1);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return std.mem.sliceTo(buffer, 0),
                .NAMETOOLONG => unreachable,
                .SRCH => unreachable,
                .FAULT => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .netbsd, .solaris, .illumos => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_getname_np(std.c.pthread_self(), buffer.ptr, max_name_len + 1);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return std.mem.sliceTo(buffer, 0),
                .INVAL => unreachable,
                .SRCH => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        .freebsd, .openbsd => if (std.Thread.use_pthreads) {
            std.c.pthread_get_name_np(std.c.pthread_self(), buffer.ptr, max_name_len + 1);
            return std.mem.sliceTo(buffer, 0);
        },
        .dragonfly => if (std.Thread.use_pthreads) {
            const err = std.c.pthread_getname_np(std.c.pthread_self(), buffer.ptr, max_name_len + 1);
            switch (@as(posix.E, @enumFromInt(err))) {
                .SUCCESS => return std.mem.sliceTo(buffer, 0),
                .INVAL => unreachable,
                .FAULT => unreachable,
                .SRCH => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        },
        else => {},
    }

    return error.Unsupported;
}
