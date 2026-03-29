//! Formatting utilities — re-exports from std.fmt.
//!
//! These helpers are platform-independent string/number formatting and parsing
//! utilities. They do not depend on OS services, sockets, files, or threads.

const re_export = struct {
    const std = @import("std");

    /// Formatting options and entry points.
    pub const Alignment = std.fmt.Alignment;
    pub const Case = std.fmt.Case;
    pub const FormatOptions = std.fmt.FormatOptions;
    pub const Options = std.fmt.Options;
    pub const default_max_depth = std.fmt.default_max_depth;
    pub const format = std.fmt.format;

    /// Buffer- and allocator-backed formatting helpers.
    pub const BufPrintError = std.fmt.BufPrintError;
    pub const allocPrint = std.fmt.allocPrint;
    pub const allocPrintSentinel = std.fmt.allocPrintSentinel;
    pub const count = std.fmt.count;
    pub const bufPrintZ = std.fmt.bufPrintZ;
    pub const bufPrint = std.fmt.bufPrint;

    /// Integer and floating-point parsing helpers.
    pub const ParseFloatError = std.fmt.ParseFloatError;
    pub const ParseIntError = std.fmt.ParseIntError;
    pub const parseFloat = std.fmt.parseFloat;
    pub const parseInt = std.fmt.parseInt;
    pub const parseIntSizeSuffix = std.fmt.parseIntSizeSuffix;
    pub const parseUnsigned = std.fmt.parseUnsigned;

    /// Digit and radix conversion helpers.
    pub const charToDigit = std.fmt.charToDigit;
    pub const digitToChar = std.fmt.digitToChar;
    pub const digits2 = std.fmt.digits2;
    pub const printInt = std.fmt.printInt;

    /// Hex encoding helpers.
    pub const bytesToHex = std.fmt.bytesToHex;
    pub const hex = std.fmt.hex;
    pub const hexToBytes = std.fmt.hexToBytes;
    pub const hex_charset = std.fmt.hex_charset;
};

pub const Alignment = re_export.Alignment;
pub const BufPrintError = re_export.BufPrintError;
pub const Case = re_export.Case;
pub const FormatOptions = re_export.FormatOptions;
pub const Options = re_export.Options;
pub const allocPrint = re_export.allocPrint;
pub const allocPrintSentinel = re_export.allocPrintSentinel;
pub const bufPrintZ = re_export.bufPrintZ;
pub const bufPrint = re_export.bufPrint;
pub const bytesToHex = re_export.bytesToHex;
pub const charToDigit = re_export.charToDigit;
pub const count = re_export.count;
pub const default_max_depth = re_export.default_max_depth;
pub const digitToChar = re_export.digitToChar;
pub const digits2 = re_export.digits2;
pub const format = re_export.format;
pub const hex = re_export.hex;
pub const hexToBytes = re_export.hexToBytes;
pub const hex_charset = re_export.hex_charset;
pub const ParseFloatError = re_export.ParseFloatError;
pub const ParseIntError = re_export.ParseIntError;
pub const parseInt = re_export.parseInt;
pub const parseFloat = re_export.parseFloat;
pub const parseIntSizeSuffix = re_export.parseIntSizeSuffix;
pub const parseUnsigned = re_export.parseUnsigned;
pub const printInt = re_export.printInt;
