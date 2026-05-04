const glib = @import("glib");
const heap = @import("esp_heap");

pub const allocator = heap.Allocator(.{
    .caps = .spiram_8bit,
});

pub fn expect(ok: bool) !void {
    if (!ok) return error.TestExpectedTrue;
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    if (!testValuesEqual(expected, actual)) {
        return error.TestExpectedEqual;
    }
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    if (expected.len != actual.len) return error.TestExpectedEqual;

    for (expected, actual) |lhs, rhs| {
        if (!glib.std.meta.eql(lhs, rhs)) {
            return error.TestExpectedEqual;
        }
    }
}

pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (!glib.std.mem.eql(u8, expected, actual)) {
        return error.TestExpectedEqual;
    }
}

pub fn expectError(expected_error: anyerror, actual_error_union: anytype) !void {
    if (actual_error_union) |_| {
        return error.TestExpectedError;
    } else |actual_error| {
        if (expected_error != actual_error) {
            return error.TestUnexpectedError;
        }
    }
}

fn testValuesEqual(expected: anytype, actual: anytype) bool {
    const Expected = @TypeOf(expected);
    const Actual = @TypeOf(actual);
    const expected_info = comptime @typeInfo(Expected);
    const actual_info = comptime @typeInfo(Actual);

    if (comptime Expected == comptime_int and Actual != comptime_int) {
        return compareComptimeIntToValue(expected, actual);
    }
    if (comptime Actual == comptime_int and Expected != comptime_int) {
        return compareComptimeIntToValue(actual, expected);
    }
    if (comptime Expected == comptime_float and Actual != comptime_float) {
        return compareComptimeFloatToValue(expected, actual);
    }
    if (comptime Actual == comptime_float and Expected != comptime_float) {
        return compareComptimeFloatToValue(actual, expected);
    }
    if (comptime expected_info == .error_set and actual_info == .error_set) {
        return @as(anyerror, expected) == @as(anyerror, actual);
    }

    return glib.std.meta.eql(expected, actual);
}

fn compareComptimeIntToValue(comptime expected: comptime_int, actual: anytype) bool {
    return switch (@typeInfo(@TypeOf(actual))) {
        .int, .comptime_int => glib.std.meta.eql(@as(@TypeOf(actual), @intCast(expected)), actual),
        .float, .comptime_float => glib.std.meta.eql(@as(@TypeOf(actual), @floatFromInt(expected)), actual),
        else => false,
    };
}

fn compareComptimeFloatToValue(comptime expected: comptime_float, actual: anytype) bool {
    return switch (@typeInfo(@TypeOf(actual))) {
        .float, .comptime_float => glib.std.meta.eql(@as(@TypeOf(actual), @floatCast(expected)), actual),
        else => false,
    };
}
