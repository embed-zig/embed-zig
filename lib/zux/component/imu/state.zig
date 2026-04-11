const motion = @import("motion");

pub const Accel = struct {
    source_id: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const Gyro = struct {
    source_id: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const Motion = struct {
    source_id: u32 = 0,
    motion: ?motion.Action = null,
};
