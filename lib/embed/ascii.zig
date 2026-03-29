//! ASCII utilities — re-exports from std.ascii.

const re_export = struct {
    const std = @import("std");

    pub const lowercase = std.ascii.lowercase;
    pub const uppercase = std.ascii.uppercase;
    pub const letters = std.ascii.letters;
    pub const whitespace = std.ascii.whitespace;
    pub const control_code = std.ascii.control_code;

    pub const isAscii = std.ascii.isAscii;
    pub const isWhitespace = std.ascii.isWhitespace;
    pub const isDigit = std.ascii.isDigit;
    pub const isHex = std.ascii.isHex;
    pub const isAlphabetic = std.ascii.isAlphabetic;
    pub const isAlphanumeric = std.ascii.isAlphanumeric;
    pub const isLower = std.ascii.isLower;
    pub const isUpper = std.ascii.isUpper;
    pub const isPrint = std.ascii.isPrint;
    pub const isControl = std.ascii.isControl;

    pub const lowerString = std.ascii.lowerString;
    pub const upperString = std.ascii.upperString;
    pub const allocLowerString = std.ascii.allocLowerString;
    pub const allocUpperString = std.ascii.allocUpperString;
    pub const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
    pub const startsWithIgnoreCase = std.ascii.startsWithIgnoreCase;
    pub const endsWithIgnoreCase = std.ascii.endsWithIgnoreCase;
    pub const indexOfIgnoreCase = std.ascii.indexOfIgnoreCase;
    pub const indexOfIgnoreCasePos = std.ascii.indexOfIgnoreCasePos;
    pub const indexOfIgnoreCasePosLinear = std.ascii.indexOfIgnoreCasePosLinear;
    pub const lessThanIgnoreCase = std.ascii.lessThanIgnoreCase;
    pub const orderIgnoreCase = std.ascii.orderIgnoreCase;
    pub const toLower = std.ascii.toLower;
    pub const toUpper = std.ascii.toUpper;
    pub const HexEscape = std.ascii.HexEscape;
    pub const hexEscape = std.ascii.hexEscape;
};

pub const lowercase = re_export.lowercase;
pub const uppercase = re_export.uppercase;
pub const letters = re_export.letters;
pub const whitespace = re_export.whitespace;
pub const control_code = re_export.control_code;

pub const isAscii = re_export.isAscii;
pub const isWhitespace = re_export.isWhitespace;
pub const isDigit = re_export.isDigit;
pub const isHex = re_export.isHex;
pub const isAlphabetic = re_export.isAlphabetic;
pub const isAlphanumeric = re_export.isAlphanumeric;
pub const isLower = re_export.isLower;
pub const isUpper = re_export.isUpper;
pub const isPrint = re_export.isPrint;
pub const isControl = re_export.isControl;

pub const lowerString = re_export.lowerString;
pub const upperString = re_export.upperString;
pub const allocLowerString = re_export.allocLowerString;
pub const allocUpperString = re_export.allocUpperString;
pub const eqlIgnoreCase = re_export.eqlIgnoreCase;
pub const startsWithIgnoreCase = re_export.startsWithIgnoreCase;
pub const endsWithIgnoreCase = re_export.endsWithIgnoreCase;
pub const indexOfIgnoreCase = re_export.indexOfIgnoreCase;
pub const indexOfIgnoreCasePos = re_export.indexOfIgnoreCasePos;
pub const indexOfIgnoreCasePosLinear = re_export.indexOfIgnoreCasePosLinear;
pub const lessThanIgnoreCase = re_export.lessThanIgnoreCase;
pub const orderIgnoreCase = re_export.orderIgnoreCase;
pub const toLower = re_export.toLower;
pub const toUpper = re_export.toUpper;
pub const HexEscape = re_export.HexEscape;
pub const hexEscape = re_export.hexEscape;
