pub const color = struct {
    pub const red: u32 = 0xff0000;
    pub const orange: u32 = 0xff7f00;
    pub const yellow: u32 = 0xffff00;
    pub const green: u32 = 0x00ff00;
    pub const cyan: u32 = 0x00ffff;
    pub const blue: u32 = 0x0000ff;
    pub const violet: u32 = 0x8b00ff;

    pub const split = [_]u32{
        red,
        orange,
        yellow,
        green,
        cyan,
        blue,
        violet,
    };
};

pub fn nextScene(scene: anytype) @TypeOf(scene) {
    return switch (scene) {
        .split_7_colors => .red,
        .red => .orange,
        .orange => .yellow,
        .yellow => .green,
        .green => .cyan,
        .cyan => .blue,
        .blue => .violet,
        .violet => .split_7_colors,
    };
}

pub fn sceneColor(scene: anytype) u32 {
    return switch (scene) {
        .red => color.red,
        .orange => color.orange,
        .yellow => color.yellow,
        .green => color.green,
        .cyan => color.cyan,
        .blue => color.blue,
        .violet => color.violet,
        .split_7_colors => color.red,
    };
}
