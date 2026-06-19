//! task — named execution-unit launcher contract.
//!
//! `task` is intentionally not a `std.Thread` wrapper. It builds a static
//! path router at comptime and delegates actual execution-unit creation to
//! platform handlers.

const builder_mod = @import("task/Builder.zig");

pub const Options = @import("task/Options.zig");
pub const Routine = @import("task/Routine.zig");
pub const BuilderOptions = builder_mod.BuilderOptions;
pub const Builder = builder_mod.Builder;
pub const BuilderWithOptions = builder_mod.BuilderWithOptions;

pub const test_runner = struct {
    pub const unit = @import("task/test_runner/unit.zig");
};
