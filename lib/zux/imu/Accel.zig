const Context = @import("../event/Context.zig");
const event = @import("../event.zig");

const Accel = @This();

ptr: *anyopaque,
source_id: u32,
ctx: Context.Type = null,
vtable: *const VTable,

pub const Sample = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Event = struct {
    pub const kind = .raw_imu_accel;

    source_id: u32,
    x: f32,
    y: f32,
    z: f32,
    ctx: Context.Type = null,
};

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque) anyerror!Sample,
};

pub fn read(self: Accel) !event.Event {
    const sample = try self.vtable.read(self.ptr);
    const accel_event: Event = .{
        .source_id = self.source_id,
        .x = sample.x,
        .y = sample.y,
        .z = sample.z,
        .ctx = self.ctx,
    };
    return .{
        .raw_imu_accel = .{
            .source_id = accel_event.source_id,
            .x = accel_event.x,
            .y = accel_event.y,
            .z = accel_event.z,
            .ctx = accel_event.ctx,
        },
    };
}

pub fn init(comptime T: type, impl: *T, source_id: u32) Accel {
    comptime {
        _ = @as(*const fn (*T) anyerror!Sample, &T.read);
    }

    const gen = struct {
        fn readFn(ptr: *anyopaque) anyerror!Sample {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.read();
        }

        const vtable = VTable{
            .read = readFn,
        };
    };

    return .{
        .ptr = @ptrCast(impl),
        .source_id = source_id,
        .ctx = null,
        .vtable = &gen.vtable,
    };
}

test "zux/imu/Accel/unit_tests/init_and_read" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,

        pub fn read(self: *@This()) !Sample {
            self.called = true;
            return .{
                .x = 1.25,
                .y = -2.5,
                .z = 3.75,
            };
        }
    };

    var impl = Impl{};
    const accel = Accel.init(Impl, &impl, 9);
    const value = try accel.read();
    switch (value) {
        .raw_imu_accel => |report| {
            try std.testing.expectEqual(@as(u32, 9), report.source_id);
            try std.testing.expectEqual(@as(f32, 1.25), report.x);
            try std.testing.expectEqual(@as(f32, -2.5), report.y);
            try std.testing.expectEqual(@as(f32, 3.75), report.z);
            try std.testing.expect(report.ctx == null);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(impl.called);
}
