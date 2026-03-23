//! std-compatible redeclarations for types that should not directly depend on
//! heavyweight std containers in production builds.

const std_re_export = @import("std_re_export.zig");

pub const Thread = struct {
    pub const SpawnError = error{
        ThreadQuotaExceeded,
        SystemResources,
        OutOfMemory,
        LockedMemoryLimitExceeded,
        Unexpected,
    };
    pub const YieldError = error{
        SystemCannotYield,
    };
    pub const CpuCountError = error{
        PermissionDenied,
        SystemResources,
        Unsupported,
        Unexpected,
    };
    pub const SetNameError = error{
        NameTooLong,
        Unsupported,
        Unexpected,
    } || std_re_export.posix.PrctlError || std_re_export.posix.WriteError || std_re_export.fs.File.OpenError || std_re_export.fmt.BufPrintError;
    pub const GetNameError = error{
        Unsupported,
        Unexpected,
    } || std_re_export.posix.PrctlError || std_re_export.posix.ReadError || std_re_export.fs.File.OpenError || std_re_export.fmt.BufPrintError;
};

pub const time = struct {
    pub const Timer = struct {
        pub const Error = error{TimerUnsupported};
    };
};

fn eqlComptime(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |byte, i| {
        if (byte != b[i]) return false;
    }
    return true;
}

fn hasErrorName(comptime errors: anytype, comptime name: []const u8) bool {
    inline for (errors) |err_decl| {
        if (eqlComptime(err_decl.name, name)) return true;
    }
    return false;
}

fn assertSameErrorSet(comptime A: type, comptime B: type) void {
    @setEvalBranchQuota(20_000);

    const a_info = @typeInfo(A);
    const b_info = @typeInfo(B);
    if (a_info != .error_set or b_info != .error_set)
        @compileError("expected error set types");

    const a_errors = a_info.error_set.?;
    const b_errors = b_info.error_set.?;

    inline for (a_errors) |a_err| {
        if (!hasErrorName(b_errors, a_err.name))
            @compileError("std_compat mismatch: missing std error " ++ a_err.name);
    }
    inline for (b_errors) |b_err| {
        if (!hasErrorName(a_errors, b_err.name))
            @compileError("std_compat mismatch: missing embed error " ++ b_err.name);
    }
}

test "Thread error sets match std" {
    const std = @import("std");

    comptime assertSameErrorSet(Thread.SpawnError, std.Thread.SpawnError);
    comptime assertSameErrorSet(Thread.YieldError, std.Thread.YieldError);
    comptime assertSameErrorSet(Thread.CpuCountError, std.Thread.CpuCountError);
    comptime assertSameErrorSet(Thread.SetNameError, std.Thread.SetNameError);
    comptime assertSameErrorSet(Thread.GetNameError, std.Thread.GetNameError);
}

test "time.Timer.Error matches std" {
    const std = @import("std");

    comptime assertSameErrorSet(time.Timer.Error, std.time.Timer.Error);
}
