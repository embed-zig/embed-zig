//! Math utilities — re-exports from std.math.

const re_export = struct {
    const std = @import("std");

    pub const IntFittingRange = std.math.IntFittingRange;
    pub const Order = std.math.Order;
    pub const maxInt = std.math.maxInt;
    pub const nan = std.math.nan;
    pub const order = std.math.order;
};

pub const IntFittingRange = re_export.IntFittingRange;
pub const Order = re_export.Order;
pub const maxInt = re_export.maxInt;
pub const nan = re_export.nan;
pub const order = re_export.order;
