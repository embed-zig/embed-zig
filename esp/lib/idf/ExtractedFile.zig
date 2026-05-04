const std = @import("std");

const Self = @This();

/// One staged input that will be materialized into the generated IDF project.
///
/// - `original_path` points at the original source/archive/include directory
/// - `idf_project_path` is the destination path inside the staged IDF project
pub const ExtractedFile = Self;

idf_project_path: []const u8,
original_path: std.Build.LazyPath,
