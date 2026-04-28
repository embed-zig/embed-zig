//! Minimal Objective-C runtime bindings for CoreBluetooth.
//!
//! Raw extern fn declarations — no @cImport, no third-party deps.
//! Provides typed wrappers around objc_msgSend, class lookup,
//! selector registration, and dynamic class creation.

const std = @import("std");

pub const Id = *anyopaque;
pub const Class = *anyopaque;
pub const SEL = *anyopaque;
pub const Protocol = *anyopaque;
pub const BOOL = i8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?Protocol;
extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern "objc" fn class_addProtocol(cls: Class, protocol: Protocol) BOOL;
extern "objc" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "objc" fn object_getInstanceVariable(obj: Id, name: [*:0]const u8, out: *?*anyopaque) ?*anyopaque;
extern "objc" fn object_setInstanceVariable(obj: Id, name: [*:0]const u8, value: ?*anyopaque) ?*anyopaque;

pub extern "objc" fn objc_msgSend() void;

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("objc: class not found");
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn getProtocol(name: [*:0]const u8) Protocol {
    return objc_getProtocol(name) orelse @panic("objc: protocol not found");
}

pub fn alloc(cls: Class) Id {
    return msgSend(Id, cls, sel("alloc"), .{});
}

pub fn release(obj: Id) void {
    msgSend(void, obj, sel("release"), .{});
}

pub fn retain(obj: Id) Id {
    return msgSend(Id, obj, sel("retain"), .{});
}

pub fn autorelease(obj: Id) Id {
    return msgSend(Id, obj, sel("autorelease"), .{});
}

/// Type-safe objc_msgSend wrapper.
/// Casts the raw objc_msgSend to a C-calling-convention function pointer
/// with the correct signature, then calls it.
pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const ArgsType = @TypeOf(args);
    const args_fields = @typeInfo(ArgsType).@"struct".fields;

    const FnType = switch (args_fields.len) {
        0 => *const fn (*anyopaque, SEL) callconv(.c) ReturnType,
        1 => *const fn (*anyopaque, SEL, args_fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (*anyopaque, SEL, args_fields[0].type, args_fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (*anyopaque, SEL, args_fields[0].type, args_fields[1].type, args_fields[2].type) callconv(.c) ReturnType,
        4 => *const fn (*anyopaque, SEL, args_fields[0].type, args_fields[1].type, args_fields[2].type, args_fields[3].type) callconv(.c) ReturnType,
        5 => *const fn (*anyopaque, SEL, args_fields[0].type, args_fields[1].type, args_fields[2].type, args_fields[3].type, args_fields[4].type) callconv(.c) ReturnType,
        6 => *const fn (*anyopaque, SEL, args_fields[0].type, args_fields[1].type, args_fields[2].type, args_fields[3].type, args_fields[4].type, args_fields[5].type) callconv(.c) ReturnType,
        else => @compileError("objc.msgSend: too many arguments (max 6)"),
    };

    const func: FnType = @ptrCast(&objc_msgSend);
    const target_ptr: *anyopaque = target;

    return @call(.auto, func, .{ target_ptr, selector } ++ args);
}

// ---- Dynamic class creation helpers ----

pub const ClassBuilder = struct {
    cls: Class,

    pub fn addMethod(self: ClassBuilder, name: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
        _ = class_addMethod(self.cls, sel(name), imp, types);
    }

    pub fn addProtocol(self: ClassBuilder, name: [*:0]const u8) void {
        if (objc_getProtocol(name)) |proto| {
            _ = class_addProtocol(self.cls, proto);
        }
    }

    pub fn addIvar(self: ClassBuilder, name: [*:0]const u8, size: usize, alignment: u8) void {
        _ = class_addIvar(self.cls, name, size, alignment, "^v");
    }

    pub fn register(self: ClassBuilder) Class {
        objc_registerClassPair(self.cls);
        return self.cls;
    }
};

pub fn allocateClassPair(superclass_name: [*:0]const u8, name: [*:0]const u8) ClassBuilder {
    const super = getClass(superclass_name);
    const cls = objc_allocateClassPair(super, name, 0) orelse @panic("objc: failed to allocate class pair");
    return .{ .cls = cls };
}

pub fn getIvar(obj: Id, name: [*:0]const u8) ?*anyopaque {
    var out: ?*anyopaque = null;
    _ = object_getInstanceVariable(obj, name, &out);
    return out;
}

pub fn setIvar(obj: Id, name: [*:0]const u8, value: ?*anyopaque) void {
    _ = object_setInstanceVariable(obj, name, value);
}

// ---- Foundation helpers ----

pub fn nsString(str: []const u8) Id {
    const NSString = getClass("NSString");
    return autorelease(msgSend(Id, alloc(NSString), sel("initWithBytes:length:encoding:"), .{
        @as(*const anyopaque, @ptrCast(str.ptr)),
        @as(NSUInteger, str.len),
        @as(NSUInteger, 4), // NSUTF8StringEncoding
    }));
}

pub fn nsStringGetBytes(nsstr: Id, buf: []u8) []const u8 {
    const utf8: ?[*]const u8 = msgSend(?[*]const u8, nsstr, sel("UTF8String"), .{});
    if (utf8) |ptr| {
        const byte_len: NSUInteger = msgSend(NSUInteger, nsstr, sel("lengthOfBytesUsingEncoding:"), .{
            @as(NSUInteger, 4), // NSUTF8StringEncoding
        });
        const copy_len = @min(byte_len, buf.len);
        @memcpy(buf[0..copy_len], ptr[0..copy_len]);
        return buf[0..copy_len];
    }
    return buf[0..0];
}

pub fn nsNumber(value: anytype) Id {
    const NSNumber = getClass("NSNumber");
    const T = @TypeOf(value);
    if (T == bool) {
        return msgSend(Id, NSNumber, sel("numberWithBool:"), .{@as(BOOL, if (value) YES else NO)});
    } else if (T == i8 or T == i16 or T == i32 or T == i64 or T == isize) {
        return msgSend(Id, NSNumber, sel("numberWithInteger:"), .{@as(NSInteger, @intCast(value))});
    } else if (T == u8 or T == u16 or T == u32 or T == u64 or T == usize) {
        return msgSend(Id, NSNumber, sel("numberWithUnsignedInteger:"), .{@as(NSUInteger, @intCast(value))});
    } else {
        @compileError("nsNumber: unsupported type");
    }
}

pub fn nsDictionary(keys: []const Id, vals: []const Id, count: NSUInteger) Id {
    const NSDictionary = getClass("NSDictionary");
    return msgSend(Id, NSDictionary, sel("dictionaryWithObjects:forKeys:count:"), .{
        @as(*const anyopaque, @ptrCast(vals.ptr)),
        @as(*const anyopaque, @ptrCast(keys.ptr)),
        count,
    });
}

pub fn nsArray(objects: []const Id, count: NSUInteger) Id {
    const NSArray = getClass("NSArray");
    return msgSend(Id, NSArray, sel("arrayWithObjects:count:"), .{
        @as(*const anyopaque, @ptrCast(objects.ptr)),
        count,
    });
}

pub fn nsData(bytes: []const u8) Id {
    const NSData = getClass("NSData");
    return msgSend(Id, NSData, sel("dataWithBytes:length:"), .{
        @as(*const anyopaque, @ptrCast(bytes.ptr)),
        @as(NSUInteger, bytes.len),
    });
}

pub fn nsDataGetBytes(data: Id, buf: []u8) []const u8 {
    const len: NSUInteger = msgSend(NSUInteger, data, sel("length"), .{});
    const copy_len = @min(len, buf.len);
    if (copy_len > 0) {
        const ptr: [*]const u8 = msgSend([*]const u8, data, sel("bytes"), .{});
        @memcpy(buf[0..copy_len], ptr[0..copy_len]);
    }
    return buf[0..copy_len];
}

pub fn cbuuid(value: u16) Id {
    const CBUUID = getClass("CBUUID");
    return msgSend(Id, CBUUID, sel("UUIDWithData:"), .{nsData(&[2]u8{
        @truncate(value >> 8),
        @truncate(value),
    })});
}

pub fn cbuuidToU16(uuid_obj: Id) u16 {
    const data: Id = msgSend(Id, uuid_obj, sel("data"), .{});
    const len: NSUInteger = msgSend(NSUInteger, data, sel("length"), .{});
    if (len == 2) {
        const ptr: [*]const u8 = msgSend([*]const u8, data, sel("bytes"), .{});
        return (@as(u16, ptr[0]) << 8) | @as(u16, ptr[1]);
    }
    return 0;
}

// ---- dispatch queue ----

pub const dispatch_queue_t = *anyopaque;
extern "System" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) dispatch_queue_t;
extern "System" fn dispatch_release(object: *anyopaque) void;

pub fn createSerialQueue(label: [*:0]const u8) dispatch_queue_t {
    return dispatch_queue_create(label, null);
}

pub fn releaseQueue(queue: dispatch_queue_t) void {
    dispatch_release(queue);
}
