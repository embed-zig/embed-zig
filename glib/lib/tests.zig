pub const std = struct {
    pub const unit = @import("tests/stdz.zig");
};

pub const testing = struct {
    pub const unit = @import("tests/testing.zig");
};

pub const context = struct {
    pub const unit = @import("tests/context.zig");
};

pub const time = struct {
    pub const unit = @import("time").test_runner.unit;
};

pub const system = struct {
    pub const unit = @import("glib_system").test_runner.unit;
};

pub const archive = struct {
    pub const unit = @import("archive").test_runner.unit;
};

pub const path = struct {
    pub const unit = @import("path").test_runner.unit;
};
