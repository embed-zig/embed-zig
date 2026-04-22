//! Imu — non-owning type-erased IMU reader.

const Imu = @This();

pub const Qmi8658 = @import("imu/qmi8658.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

// A single backend read can return whichever sensor groups it supports.
pub const Sample = struct {
    accel: ?Vec3 = null,
    gyro: ?Vec3 = null,
    temperature_c: ?f32 = null,
};

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque) anyerror!Sample,
};

pub fn read(self: Imu) !Sample {
    return self.vtable.read(self.ptr);
}

pub fn init(pointer: anytype) Imu {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Imu.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFn(ptr: *anyopaque) anyerror!Sample {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read();
        }

        const vtable = VTable{
            .read = readFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn fromQMI8658(pointer: *Qmi8658) Imu {
    const gen = struct {
        fn readFn(ptr: *anyopaque) anyerror!Sample {
            const self: *Qmi8658 = @ptrCast(@alignCast(ptr));
            const scaled = try self.readScaled();
            return .{
                .accel = .{
                    .x = scaled.acc_x,
                    .y = scaled.acc_y,
                    .z = scaled.acc_z,
                },
                .gyro = .{
                    .x = scaled.gyr_x,
                    .y = scaled.gyr_y,
                    .z = scaled.gyr_z,
                },
                .temperature_c = null,
            };
        }

        const vtable = VTable{
            .read = readFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
