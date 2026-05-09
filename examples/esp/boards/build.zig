const std = @import("std");
const boards = @import("boards.zig");

pub const createBuildConfigModule = boards.createBuildConfigModule;
pub const createBoardModule = boards.createBoardModule;
pub const addComponent = boards.addComponent;

pub fn build(_: *std.Build) void {}
