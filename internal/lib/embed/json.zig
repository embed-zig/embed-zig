//! JSON utilities — re-exports from std.json.
//!
//! These helpers are platform-independent JSON parsing and stringification
//! utilities. They mirror `std.json` so `embed.json` can be used with the same
//! source-level API where those symbols are exposed.

const root = @This();

const re_export = struct {
    const std = @import("std");

    pub const ObjectMap = std.json.ObjectMap;
    pub const Array = std.json.Array;
    pub const Value = std.json.Value;

    pub const ArrayHashMap = std.json.ArrayHashMap;

    pub const Scanner = std.json.Scanner;
    pub const validate = std.json.validate;
    pub const Error = std.json.Error;
    pub const default_buffer_size = std.json.default_buffer_size;
    pub const Token = std.json.Token;
    pub const TokenType = std.json.TokenType;
    pub const Diagnostics = std.json.Diagnostics;
    pub const AllocWhen = std.json.AllocWhen;
    pub const default_max_value_len = std.json.default_max_value_len;
    pub const Reader = std.json.Reader;
    pub const isNumberFormattedLikeAnInteger = std.json.isNumberFormattedLikeAnInteger;

    pub const ParseOptions = std.json.ParseOptions;
    pub const Parsed = std.json.Parsed;
    pub const parseFromSlice = std.json.parseFromSlice;
    pub const parseFromSliceLeaky = std.json.parseFromSliceLeaky;
    pub const parseFromTokenSource = std.json.parseFromTokenSource;
    pub const parseFromTokenSourceLeaky = std.json.parseFromTokenSourceLeaky;
    pub const innerParse = std.json.innerParse;
    pub const parseFromValue = std.json.parseFromValue;
    pub const parseFromValueLeaky = std.json.parseFromValueLeaky;
    pub const innerParseFromValue = std.json.innerParseFromValue;
    pub const ParseError = std.json.ParseError;
    pub const ParseFromValueError = std.json.ParseFromValueError;

    pub const Stringify = std.json.Stringify;
    pub const fmt = std.json.fmt;
    pub const Formatter = std.json.Formatter;
};

pub const ObjectMap = re_export.ObjectMap;
pub const Array = re_export.Array;
pub const Value = re_export.Value;

pub const ArrayHashMap = re_export.ArrayHashMap;

pub const Scanner = re_export.Scanner;
pub const validate = re_export.validate;
pub const Error = re_export.Error;
pub const default_buffer_size = re_export.default_buffer_size;
pub const Token = re_export.Token;
pub const TokenType = re_export.TokenType;
pub const Diagnostics = re_export.Diagnostics;
pub const AllocWhen = re_export.AllocWhen;
pub const default_max_value_len = re_export.default_max_value_len;
pub const Reader = re_export.Reader;
pub const isNumberFormattedLikeAnInteger = re_export.isNumberFormattedLikeAnInteger;

pub const ParseOptions = re_export.ParseOptions;
pub const Parsed = re_export.Parsed;
pub const parseFromSlice = re_export.parseFromSlice;
pub const parseFromSliceLeaky = re_export.parseFromSliceLeaky;
pub const parseFromTokenSource = re_export.parseFromTokenSource;
pub const parseFromTokenSourceLeaky = re_export.parseFromTokenSourceLeaky;
pub const innerParse = re_export.innerParse;
pub const parseFromValue = re_export.parseFromValue;
pub const parseFromValueLeaky = re_export.parseFromValueLeaky;
pub const innerParseFromValue = re_export.innerParseFromValue;
pub const ParseError = re_export.ParseError;
pub const ParseFromValueError = re_export.ParseFromValueError;

pub const Stringify = re_export.Stringify;
pub const fmt = re_export.fmt;
pub const Formatter = re_export.Formatter;

