pub const BuildContext = @import("armino/BuildContext.zig");
pub const Config = @import("armino/Config.zig");
pub const Component = @import("armino/Component.zig");
pub const DualCoreApp = @import("armino/App.zig");
pub const PartitionTable = @import("armino/PartitionTable.zig");
pub const RamRegions = @import("armino/RamRegions.zig");
pub const ipc = @import("armino/ipc.zig");
pub const system = @import("armino/system.zig");

pub const resolveBuildContext = BuildContext.resolve;
pub const addDualCoreApp = DualCoreApp.addDualCoreApp;
