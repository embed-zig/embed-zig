const Context = @import("../../event/Context.zig");
const motion = @import("motion");

pub const Accel = struct {
    pub const kind = .raw_imu_accel;

    source_id: u32,
    x: f32,
    y: f32,
    z: f32,
    ctx: Context.Type = null,
};

pub const Gyro = struct {
    pub const kind = .raw_imu_gyro;

    source_id: u32,
    x: f32,
    y: f32,
    z: f32,
    ctx: Context.Type = null,
};

pub const Motion = struct {
    pub const kind = .imu_motion;

    source_id: u32,
    motion: motion.Action,
    ctx: Context.Type = null,
};
