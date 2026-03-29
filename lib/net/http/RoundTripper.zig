//! RoundTripper — type-erased HTTP round tripper (like Go's `http.RoundTripper`).
//!
//! VTable-based runtime dispatch. Any concrete round tripper with a
//! `roundTrip` method can be wrapped into a RoundTripper.
//!
//! Allocation policy is carried on the request via `Request.allocator`.
//!
//! Usage:
//!   const http = @import("net/http.zig");
//!   var round_tripper = http.RoundTripper.init(&mock_round_tripper);
//!   var req = try http.Request.init(std.testing.allocator, "GET", "https://example.com");
//!   const resp = try round_tripper.roundTrip(&req);
//!   _ = resp.body();

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const RoundTripper = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const RoundTripError = anyerror;

pub const VTable = struct {
    roundTrip: *const fn (ptr: *anyopaque, req: *const Request) RoundTripError!Response,
};

pub fn roundTrip(self: RoundTripper, req: *const Request) RoundTripError!Response {
    return self.vtable.roundTrip(self.ptr, req);
}

/// Wrap a pointer to any concrete round tripper into a RoundTripper.
///
/// The concrete type must provide:
///   fn roundTrip(*Self, *const Request) RoundTripError!Response
pub fn init(pointer: anytype) RoundTripper {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("RoundTripper.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn roundTripFn(ptr: *anyopaque, req: *const Request) RoundTripError!Response {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.roundTrip(req);
        }

        const vtable = VTable{
            .roundTrip = roundTripFn,
        };
    };

    return .{ .ptr = pointer, .vtable = &gen.vtable };
}
