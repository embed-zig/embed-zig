//! `std.Random`-compatible random interface with a curated algorithm surface.

const std = @import("std");
const StdRandom = std.Random;

const Random = @This();

ptr: *anyopaque,
fillFn: *const fn (ptr: *anyopaque, buf: []u8) void,

pub fn init(pointer: anytype, comptime fillFn: fn (ptr: @TypeOf(pointer), buf: []u8) void) Random {
    const rand = StdRandom.init(pointer, fillFn);
    return .{
        .ptr = rand.ptr,
        .fillFn = rand.fillFn,
    };
}

pub fn bytes(r: Random, buf: []u8) void {
    StdRandom.bytes(r.toStd(), buf);
}

pub fn boolean(r: Random) bool {
    return StdRandom.boolean(r.toStd());
}

pub inline fn enumValue(r: Random, comptime EnumType: type) EnumType {
    return StdRandom.enumValue(r.toStd(), EnumType);
}

pub fn enumValueWithIndex(r: Random, comptime EnumType: type, comptime Index: type) EnumType {
    return StdRandom.enumValueWithIndex(r.toStd(), EnumType, Index);
}

pub fn int(r: Random, comptime T: type) T {
    return StdRandom.int(r.toStd(), T);
}

pub fn uintLessThanBiased(r: Random, comptime T: type, less_than: T) T {
    return StdRandom.uintLessThanBiased(r.toStd(), T, less_than);
}

pub fn uintLessThan(r: Random, comptime T: type, less_than: T) T {
    return StdRandom.uintLessThan(r.toStd(), T, less_than);
}

pub fn uintAtMostBiased(r: Random, comptime T: type, at_most: T) T {
    return StdRandom.uintAtMostBiased(r.toStd(), T, at_most);
}

pub fn uintAtMost(r: Random, comptime T: type, at_most: T) T {
    return StdRandom.uintAtMost(r.toStd(), T, at_most);
}

pub fn intRangeLessThanBiased(r: Random, comptime T: type, at_least: T, less_than: T) T {
    return StdRandom.intRangeLessThanBiased(r.toStd(), T, at_least, less_than);
}

pub fn intRangeLessThan(r: Random, comptime T: type, at_least: T, less_than: T) T {
    return StdRandom.intRangeLessThan(r.toStd(), T, at_least, less_than);
}

pub fn intRangeAtMostBiased(r: Random, comptime T: type, at_least: T, at_most: T) T {
    return StdRandom.intRangeAtMostBiased(r.toStd(), T, at_least, at_most);
}

pub fn intRangeAtMost(r: Random, comptime T: type, at_least: T, at_most: T) T {
    return StdRandom.intRangeAtMost(r.toStd(), T, at_least, at_most);
}

pub fn float(r: Random, comptime T: type) T {
    return StdRandom.float(r.toStd(), T);
}

pub fn floatNorm(r: Random, comptime T: type) T {
    return StdRandom.floatNorm(r.toStd(), T);
}

pub fn floatExp(r: Random, comptime T: type) T {
    return StdRandom.floatExp(r.toStd(), T);
}

pub inline fn shuffle(r: Random, comptime T: type, buf: []T) void {
    StdRandom.shuffle(r.toStd(), T, buf);
}

pub fn shuffleWithIndex(r: Random, comptime T: type, buf: []T, comptime Index: type) void {
    StdRandom.shuffleWithIndex(r.toStd(), T, buf, Index);
}

pub fn weightedIndex(r: Random, comptime T: type, proportions: []const T) usize {
    return StdRandom.weightedIndex(r.toStd(), T, proportions);
}

pub fn limitRangeBiased(comptime T: type, random_int: T, less_than: T) T {
    return StdRandom.limitRangeBiased(T, random_int, less_than);
}

fn toStd(r: Random) StdRandom {
    return .{
        .ptr = r.ptr,
        .fillFn = r.fillFn,
    };
}

