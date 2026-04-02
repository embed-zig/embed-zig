const Context = @import("../event/Context.zig");
const event = @import("../event.zig");

const Gyro = @This();

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
    pub const kind = .raw_imu_gyro;

    source_id: u32,
    x: f32,
    y: f32,
    z: f32,
    ctx: Context.Type = null,
};

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque) anyerror!Sample,
};

pub fn read(self: Gyro) !event.Event {
    const sample = try self.vtable.read(self.ptr);
    const gyro_event: Event = .{
        .source_id = self.source_id,
        .x = sample.x,
        .y = sample.y,
        .z = sample.z,
        .ctx = self.ctx,
    };
    return .{
        .raw_imu_gyro = .{
            .source_id = gyro_event.source_id,
            .x = gyro_event.x,
            .y = gyro_event.y,
            .z = gyro_event.z,
            .ctx = gyro_event.ctx,
        },
    };
}

pub fn init(comptime T: type, impl: *T, source_id: u32) Gyro {
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

test "zux/imu/Gyro/unit_tests/init_and_read" {
    const std = @import("std");

    const Impl = struct {
        called: bool = false,

        pub fn read(self: *@This()) !Sample {
            self.called = true;
            return .{
                .x = -11.0,
                .y = 0.5,
                .z = 42.25,
            };
        }
    };

    var impl = Impl{};
    const gyro = Gyro.init(Impl, &impl, 13);
    const value = try gyro.read();
    switch (value) {
        .raw_imu_gyro => |report| {
            try std.testing.expectEqual(@as(u32, 13), report.source_id);
            try std.testing.expectEqual(@as(f32, -11.0), report.x);
            try std.testing.expectEqual(@as(f32, 0.5), report.y);
            try std.testing.expectEqual(@as(f32, 42.25), report.z);
            try std.testing.expect(report.ctx == null);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(impl.called);
}
