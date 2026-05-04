pub const SdkConfig = @import("idf/SdkConfig.zig");
pub const PartitionTable = @import("idf/PartitionTable.zig");
pub const BuildContext = @import("idf/BuildContext.zig");
pub const Component = @import("idf/Component.zig");
pub const ExtractedFile = @import("idf/ExtractedFile.zig");
pub const Project = @import("idf/Project.zig");
pub const idf_commands = @import("idf/idf_commands.zig");
pub const tools = @import("idf/tools.zig");
pub const fs_utils = @import("idf/utils/fs.zig");
pub const path_utils = @import("idf/utils/path.zig");
const AppModule = @import("idf/App.zig");

pub const ToolchainSysroot = BuildContext.ToolchainSysroot;
pub const ResolveBuildContextOptions = BuildContext.ResolveBuildContextOptions;

pub const RuntimeOptions = AppModule.RuntimeOptions;
pub const App = AppModule;
pub const AppEntry = AppModule.Entry;
pub const AddAppOptions = AppModule.AddOptions;
pub const resolveBuildContext = BuildContext.resolveBuildContext;
pub const addApp = AppModule.addApp;

test "idf/unit_tests" {
    _ = @import("idf/zig_shim/shim.zig");
    _ = @import("idf/SdkConfig.zig");
    _ = @import("idf/PartitionTable.zig");
    _ = @import("idf/BuildContext.zig");
    _ = @import("idf/Component.zig");
    _ = @import("idf/ExtractedFile.zig");
    _ = @import("idf/Project.zig");
    _ = @import("idf/idf_commands.zig");
    _ = @import("idf/tools.zig");
    _ = @import("idf/utils/path.zig");
    _ = @import("idf/utils/fs.zig");
    _ = @import("idf/App.zig");
    _ = @import("idf/tools/generate_app_main.zig");
}
