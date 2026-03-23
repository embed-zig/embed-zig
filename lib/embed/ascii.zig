//! ASCII utilities — re-exports from std.ascii.

const std = @import("std_re_export.zig");

pub const whitespace = std.ascii.whitespace;
pub const isWhitespace = std.ascii.isWhitespace;
pub const isDigit = std.ascii.isDigit;
pub const isHex = std.ascii.isHex;
pub const isAlphabetic = std.ascii.isAlphabetic;
pub const isAlphanumeric = std.ascii.isAlphanumeric;
pub const isLower = std.ascii.isLower;
pub const isUpper = std.ascii.isUpper;
pub const isPrint = std.ascii.isPrint;
pub const isControl = std.ascii.isControl;
pub const isPunctuation = std.ascii.isPunctuation;
pub const isSpace = std.ascii.isSpace;
pub const lowerString = std.ascii.lowerString;
pub const upperString = std.ascii.upperString;
pub const allocLowerString = std.ascii.allocLowerString;
pub const allocUpperString = std.ascii.allocUpperString;
pub const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
pub const startsWithIgnoreCase = std.ascii.startsWithIgnoreCase;
pub const endsWithIgnoreCase = std.ascii.endsWithIgnoreCase;
pub const lessThanIgnoreCase = std.ascii.lessThanIgnoreCase;
pub const orderIgnoreCase = std.ascii.orderIgnoreCase;
pub const toLower = std.ascii.toLower;
pub const toUpper = std.ascii.toUpper;
