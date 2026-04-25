pub const std = struct {
    pub const unit = @import("tests/stdz.zig");
};

pub const testing = struct {
    pub const unit = @import("tests/testing.zig");
};

pub const context = struct {
    pub const unit = @import("tests/context.zig");
};
