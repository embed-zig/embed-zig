const std = @import("std");
const binding = @import("thread/binding.zig");

pub fn Value(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub fn load(self: *const Self, comptime order: std.builtin.AtomicOrder) T {
            _ = order;
            criticalEnter();
            defer criticalExit();
            return self.raw;
        }

        pub fn store(self: *Self, value: T, comptime order: std.builtin.AtomicOrder) void {
            _ = order;
            criticalEnter();
            defer criticalExit();
            self.raw = value;
        }

        pub fn swap(self: *Self, value: T, comptime order: std.builtin.AtomicOrder) T {
            _ = order;
            criticalEnter();
            defer criticalExit();

            const prev = self.raw;
            self.raw = value;
            return prev;
        }

        pub fn cmpxchgWeak(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) ?T {
            return cmpxchg(self, expected_value, new_value, success_order, failure_order);
        }

        pub fn cmpxchgStrong(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) ?T {
            return cmpxchg(self, expected_value, new_value, success_order, failure_order);
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime order: std.builtin.AtomicOrder) T {
            _ = order;
            comptime requireInt(T, "fetchAdd");
            criticalEnter();
            defer criticalExit();

            const prev = self.raw;
            self.raw = prev +% operand;
            return prev;
        }

        pub fn fetchSub(self: *Self, operand: T, comptime order: std.builtin.AtomicOrder) T {
            _ = order;
            comptime requireInt(T, "fetchSub");
            criticalEnter();
            defer criticalExit();

            const prev = self.raw;
            self.raw = prev -% operand;
            return prev;
        }

        fn cmpxchg(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) ?T {
            _ = success_order;
            _ = failure_order;
            criticalEnter();
            defer criticalExit();

            if (self.raw == expected_value) {
                self.raw = new_value;
                return null;
            }
            return self.raw;
        }
    };
}

fn criticalEnter() void {
    binding.espz_freertos_global_critical_enter();
}

fn criticalExit() void {
    binding.espz_freertos_global_critical_exit();
}

fn requireInt(comptime T: type, comptime name: []const u8) void {
    switch (@typeInfo(T)) {
        .int, .comptime_int => {},
        else => @compileError("freertos.atomic.Value(" ++ @typeName(T) ++ ")." ++ name ++ " requires an integer type"),
    }
}
