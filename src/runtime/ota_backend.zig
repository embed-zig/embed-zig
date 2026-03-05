//! Runtime OTA backend contract (write + confirm/rollback lifecycle).

pub const Error = error{
    InitFailed,
    OpenFailed,
    WriteFailed,
    FinalizeFailed,
    AbortFailed,
    ConfirmFailed,
    RollbackFailed,
};

pub const State = enum {
    unknown,
    pending_verify,
    valid,
    invalid,
};

/// OTA backend contract:
/// - `init() -> Error!Impl`
/// - `begin(self: *Impl, image_size: u32) -> Error!void`
/// - `write(self: *Impl, chunk: []const u8) -> Error!void`
/// - `finalize(self: *Impl) -> Error!void`
/// - `abort(self: *Impl) -> void`
/// - `confirm(self: *Impl) -> Error!void`
/// - `rollback(self: *Impl) -> Error!void`
/// - `getState(self: *Impl) -> State`
pub fn from(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Error!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, u32) Error!void, &Impl.begin);
        _ = @as(*const fn (*Impl, []const u8) Error!void, &Impl.write);
        _ = @as(*const fn (*Impl) Error!void, &Impl.finalize);
        _ = @as(*const fn (*Impl) void, &Impl.abort);
        _ = @as(*const fn (*Impl) Error!void, &Impl.confirm);
        _ = @as(*const fn (*Impl) Error!void, &Impl.rollback);
        _ = @as(*const fn (*Impl) State, &Impl.getState);
    }
    return Impl;
}
