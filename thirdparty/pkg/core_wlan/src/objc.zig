//! Minimal Objective-C runtime bindings for CoreWLAN.

pub const Id = *anyopaque;
pub const Class = *anyopaque;
pub const SEL = *anyopaque;
pub const BOOL = i8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;

pub extern "objc" fn objc_msgSend() void;

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("objc: class not found");
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn alloc(cls: Class) Id {
    return msgSend(Id, cls, sel("alloc"), .{});
}

pub fn release(obj: Id) void {
    msgSend(void, obj, sel("release"), .{});
}

pub fn autorelease(obj: Id) Id {
    return msgSend(Id, obj, sel("autorelease"), .{});
}

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
        else => @compileError("objc.msgSend: too many arguments (max 5)"),
    };

    const func: FnType = @ptrCast(&objc_msgSend);
    const target_ptr: *anyopaque = target;
    return @call(.auto, func, .{ target_ptr, selector } ++ args);
}

pub fn nsString(str: []const u8) Id {
    const NSString = getClass("NSString");
    return autorelease(msgSend(Id, alloc(NSString), sel("initWithBytes:length:encoding:"), .{
        @as(*const anyopaque, @ptrCast(str.ptr)),
        @as(NSUInteger, str.len),
        @as(NSUInteger, 4),
    }));
}

pub fn nsStringGetBytes(nsstr: Id, buf: []u8) []const u8 {
    const utf8: ?[*]const u8 = msgSend(?[*]const u8, nsstr, sel("UTF8String"), .{});
    if (utf8) |ptr| {
        const byte_len: NSUInteger = msgSend(NSUInteger, nsstr, sel("lengthOfBytesUsingEncoding:"), .{
            @as(NSUInteger, 4),
        });
        const copy_len = @min(byte_len, buf.len);
        @memcpy(buf[0..copy_len], ptr[0..copy_len]);
        return buf[0..copy_len];
    }
    return buf[0..0];
}

pub const AutoreleasePool = struct {
    pool: Id,

    pub fn init() AutoreleasePool {
        const NSAutoreleasePool = getClass("NSAutoreleasePool");
        return .{
            .pool = msgSend(Id, alloc(NSAutoreleasePool), sel("init"), .{}),
        };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        msgSend(void, self.pool, sel("drain"), .{});
    }
};
