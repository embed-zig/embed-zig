//! Formatting utilities — re-exports from std.fmt.
//!
//! These helpers are platform-independent string/number formatting and parsing
//! utilities. They do not depend on OS services, sockets, files, or threads.

const std = @import("std");

pub const allocPrint = std.fmt.allocPrint;
pub const bufPrint = std.fmt.bufPrint;
pub const parseInt = std.fmt.parseInt;
