//! Channel contract — typed, bounded, multi-producer/multi-consumer.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const IntChan = sync.ChannelFactory(platform.Channel).Channel(u32);
//!   var ch = try IntChan.make(allocator, 16);
//!   defer ch.deinit();
//!   try ch.send(42);
//!   const result = try ch.recv();

const std = @import("std");

pub fn SendResult() type {
    return struct { ok: bool };
}

pub fn RecvResult(comptime T: type) type {
    return struct { value: T, ok: bool };
}

/// Construct a sealed Channel factory from a platform Impl.
///
/// Impl must be: fn(type) type
/// The returned type for a given T must provide:
///   fn init(Allocator, usize) !Ch
///   fn deinit(*Ch) void
///   fn close(*Ch) void
///   fn send(*Ch, T) anyerror!SendResult()
///   fn recv(*Ch) anyerror!RecvResult(T)
pub fn makeFactory(comptime impl: fn (type) type) type {
    return struct {
        pub fn Channel(comptime T: type) type {
            const Ch = impl(T);

            comptime {
                _ = @as(*const fn (*Ch, T) anyerror!SendResult(), &Ch.send);
                _ = @as(*const fn (*Ch) anyerror!RecvResult(T), &Ch.recv);
                _ = @as(*const fn (*Ch) void, &Ch.close);
                _ = @as(*const fn (*Ch) void, &Ch.deinit);
                _ = @as(*const fn (std.mem.Allocator, usize) anyerror!Ch, &Ch.init);
            }

            return struct {
                ch: Ch,

                const Self = @This();

                pub fn make(allocator: std.mem.Allocator, capacity: usize) !Self {
                    return .{ .ch = try Ch.init(allocator, capacity) };
                }

                pub fn deinit(self: *Self) void {
                    self.ch.deinit();
                }

                pub fn close(self: *Self) void {
                    self.ch.close();
                }

                pub fn send(self: *Self, value: T) !SendResult() {
                    return self.ch.send(value);
                }

                pub fn recv(self: *Self) !RecvResult(T) {
                    return self.ch.recv();
                }
            };
        }
    };
}
