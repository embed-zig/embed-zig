const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const ota = esp.app_metadata.ota;
const OtaError = runtime.ota_backend.Error;
const State = runtime.ota_backend.State;

pub const OtaBackend = struct {
    handle: ?ota.Handle = null,
    partition: ota.PartitionHandle = null,
    expected_size: u32 = 0,
    written_size: u32 = 0,

    pub fn init() OtaError!@This() {
        return .{};
    }

    pub fn begin(self: *@This(), image_size: u32) OtaError!void {
        self.abort();
        self.expected_size = image_size;
        self.written_size = 0;

        self.partition = ota.getNextUpdatePartition() catch return error.OpenFailed;
        self.handle = ota.begin(self.partition, image_size) catch return error.OpenFailed;
    }

    pub fn write(self: *@This(), chunk: []const u8) OtaError!void {
        const h = self.handle orelse return error.WriteFailed;
        ota.write(h, chunk) catch return error.WriteFailed;

        const next = @as(u64, self.written_size) + chunk.len;
        self.written_size = if (next > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(next);
    }

    pub fn finalize(self: *@This()) OtaError!void {
        const h = self.handle orelse return error.FinalizeFailed;
        self.handle = null;

        ota.end(h) catch return error.FinalizeFailed;

        if (self.expected_size != 0 and self.written_size != self.expected_size) {
            return error.FinalizeFailed;
        }

        ota.setBootPartition(self.partition) catch return error.FinalizeFailed;
    }

    pub fn abort(self: *@This()) void {
        if (self.handle) |h| {
            ota.abort(h);
            self.handle = null;
        }
        self.partition = null;
    }

    pub fn confirm(_: *@This()) OtaError!void {
        ota.markValid() catch return error.ConfirmFailed;
    }

    pub fn rollback(_: *@This()) OtaError!void {
        ota.markInvalidAndRollback() catch return error.RollbackFailed;
    }

    pub fn getState(_: *@This()) State {
        const running = ota.getRunningPartition() catch return .unknown;
        const app_state = ota.getPartitionState(running) catch return .unknown;
        return switch (app_state) {
            .new, .pending_verify => .pending_verify,
            .valid => .valid,
            .invalid, .aborted => .invalid,
            .undefined => .unknown,
        };
    }
};
