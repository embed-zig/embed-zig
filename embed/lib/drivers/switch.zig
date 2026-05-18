const glib = @import("glib");

pub const Switch = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = anyerror;

    pub const VTable = struct {
        set: *const fn (ptr: *anyopaque, enabled: bool) Error!void,
        get: ?*const fn (ptr: *anyopaque) Error!bool = null,
    };

    pub fn init(pointer: anytype) Self {
        const Impl = childType(@TypeOf(pointer), "Switch.init");

        comptime {
            _ = @as(*const fn (*Impl, bool) Error!void, &Impl.set);
        }

        const gen = struct {
            fn setFn(ptr: *anyopaque, enabled: bool) Error!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                try self.set(enabled);
            }

            fn getFn(ptr: *anyopaque) Error!bool {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (comptime @hasDecl(Impl, "get")) {
                    return self.get();
                }
                return error.Unsupported;
            }

            const vtable = VTable{
                .set = setFn,
                .get = getFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn set(self: Self, enabled: bool) Error!void {
        try self.vtable.set(self.ptr, enabled);
    }

    pub fn get(self: Self) Error!bool {
        const get_fn = self.vtable.get orelse return error.Unsupported;
        return get_fn(self.ptr);
    }
};

pub const Pwm = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = anyerror;

    pub const Duty = struct {
        const DutyValue = @This();

        numerator: u32,
        denominator: u32,

        pub const zero = DutyValue{ .numerator = 0, .denominator = 1 };
        pub const full = DutyValue{ .numerator = 1, .denominator = 1 };

        pub fn init(numerator: u32, denominator: u32) DutyValue {
            if (denominator == 0) @panic("Pwm.Duty denominator must be > 0");
            if (numerator > denominator) @panic("Pwm.Duty numerator must be <= denominator");
            return .{ .numerator = numerator, .denominator = denominator };
        }
    };

    pub const VTable = struct {
        setFrequencyHz: *const fn (ptr: *anyopaque, hz: u32) Error!void,
        setDuty: *const fn (ptr: *anyopaque, duty: Duty) Error!void,
        enable: *const fn (ptr: *anyopaque) Error!void,
        disable: *const fn (ptr: *anyopaque) Error!void,
    };

    pub fn init(pointer: anytype) Self {
        const Impl = childType(@TypeOf(pointer), "Pwm.init");

        comptime {
            _ = @as(*const fn (*Impl, u32) Error!void, &Impl.setFrequencyHz);
            _ = @as(*const fn (*Impl, Duty) Error!void, &Impl.setDuty);
            _ = @as(*const fn (*Impl) Error!void, &Impl.enable);
            _ = @as(*const fn (*Impl) Error!void, &Impl.disable);
        }

        const gen = struct {
            fn setFrequencyHzFn(ptr: *anyopaque, hz: u32) Error!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                try self.setFrequencyHz(hz);
            }

            fn setDutyFn(ptr: *anyopaque, duty: Duty) Error!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                try self.setDuty(duty);
            }

            fn enableFn(ptr: *anyopaque) Error!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                try self.enable();
            }

            fn disableFn(ptr: *anyopaque) Error!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                try self.disable();
            }

            const vtable = VTable{
                .setFrequencyHz = setFrequencyHzFn,
                .setDuty = setDutyFn,
                .enable = enableFn,
                .disable = disableFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn setFrequencyHz(self: Self, hz: u32) Error!void {
        try self.vtable.setFrequencyHz(self.ptr, hz);
    }

    pub fn setDuty(self: Self, duty: Duty) Error!void {
        try self.vtable.setDuty(self.ptr, duty);
    }

    pub fn enable(self: Self) Error!void {
        try self.vtable.enable(self.ptr);
    }

    pub fn disable(self: Self) Error!void {
        try self.vtable.disable(self.ptr);
    }
};

fn childType(comptime PointerType: type, comptime name: []const u8) type {
    return switch (@typeInfo(PointerType)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => pointer.child,
            else => @compileError(name ++ " expects a single-item pointer"),
        },
        else => @compileError(name ++ " expects a pointer"),
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn switchDispatchesSetAndGet() !void {
            const Impl = struct {
                enabled: bool = false,

                fn set(self: *@This(), enabled: bool) Switch.Error!void {
                    self.enabled = enabled;
                }

                fn get(self: *@This()) Switch.Error!bool {
                    return self.enabled;
                }
            };

            var impl = Impl{};
            const sw = Switch.init(&impl);
            try sw.set(true);
            try grt.std.testing.expect(try sw.get());
            try sw.set(false);
            try grt.std.testing.expect(!try sw.get());
        }

        fn switchGetWithoutBackendReportsUnsupported() !void {
            const Impl = struct {
                fn set(_: *@This(), _: bool) Switch.Error!void {}
            };

            var impl = Impl{};
            const sw = Switch.init(&impl);
            try grt.std.testing.expectError(error.Unsupported, sw.get());
        }

        fn pwmDispatchesControlCalls() !void {
            const Impl = struct {
                hz: u32 = 0,
                duty: Pwm.Duty = .zero,
                enabled: bool = false,

                fn setFrequencyHz(self: *@This(), hz: u32) Pwm.Error!void {
                    self.hz = hz;
                }

                fn setDuty(self: *@This(), duty: Pwm.Duty) Pwm.Error!void {
                    self.duty = duty;
                }

                fn enable(self: *@This()) Pwm.Error!void {
                    self.enabled = true;
                }

                fn disable(self: *@This()) Pwm.Error!void {
                    self.enabled = false;
                }
            };

            var impl = Impl{};
            const pwm = Pwm.init(&impl);
            try pwm.setFrequencyHz(1000);
            try pwm.setDuty(Pwm.Duty.init(1, 4));
            try pwm.enable();

            try grt.std.testing.expectEqual(@as(u32, 1000), impl.hz);
            try grt.std.testing.expectEqual(@as(u32, 1), impl.duty.numerator);
            try grt.std.testing.expectEqual(@as(u32, 4), impl.duty.denominator);
            try grt.std.testing.expect(impl.enabled);

            try pwm.disable();
            try grt.std.testing.expect(!impl.enabled);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            inline for (.{
                TestCase.switchDispatchesSetAndGet,
                TestCase.switchGetWithoutBackendReportsUnsupported,
                TestCase.pwmDispatchesControlCalls,
            }) |case| {
                case() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
