const glib = @import("glib");

pub const AdcButton = @import("button/AdcButton.zig");
pub const GpioButton = @import("button/GpioButton.zig");

pub const Single = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isPressed: *const fn (ptr: *anyopaque) anyerror!bool,
    };

    pub fn init(comptime T: type, impl: *T) Single {
        comptime {
            _ = @as(*const fn (*T) anyerror!bool, &T.isPressed);
        }

        const gen = struct {
            fn isPressedFn(ptr: *anyopaque) anyerror!bool {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.isPressed();
            }

            const vtable = VTable{
                .isPressed = isPressedFn,
            };
        };

        return .{
            .ptr = @ptrCast(impl),
            .vtable = &gen.vtable,
        };
    }

    pub fn fromGpioButton(pointer: anytype) Single {
        const T = childType(@TypeOf(pointer));
        return init(T, pointer);
    }

    pub fn isPressed(self: Single) anyerror!bool {
        return self.vtable.isPressed(self.ptr);
    }
};

pub const Grouped = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        pressedButtonId: *const fn (ptr: *anyopaque) anyerror!?u32,
    };

    pub fn init(comptime T: type, impl: *T) Grouped {
        const has_pressed_button_id = comptime @hasDecl(T, "pressedButtonId");
        const has_pressed_button = comptime @hasDecl(T, "pressedButton");

        comptime {
            if (has_pressed_button_id) {
                _ = @as(*const fn (*T) anyerror!?u32, &T.pressedButtonId);
            } else if (has_pressed_button) {
                _ = @as(*const fn (*T) anyerror!?u32, &T.pressedButton);
            } else {
                @compileError("drivers.button.Grouped.init requires T.pressedButtonId() or T.pressedButton()");
            }
        }

        const gen = struct {
            fn pressedButtonIdFn(ptr: *anyopaque) anyerror!?u32 {
                const self: *T = @ptrCast(@alignCast(ptr));
                if (comptime has_pressed_button_id) {
                    return self.pressedButtonId();
                }
                return self.pressedButton();
            }

            const vtable = VTable{
                .pressedButtonId = pressedButtonIdFn,
            };
        };

        return .{
            .ptr = @ptrCast(impl),
            .vtable = &gen.vtable,
        };
    }

    pub fn fromAdcButton(pointer: anytype) Grouped {
        const T = childType(@TypeOf(pointer));
        return init(T, pointer);
    }

    pub fn pressedButtonId(self: Grouped) anyerror!?u32 {
        return self.vtable.pressedButtonId(self.ptr);
    }

    pub fn pressedButton(self: Grouped) anyerror!?u32 {
        return self.pressedButtonId();
    }
};

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn singleInitCallsIsPressed() !void {
            const Impl = struct {
                called: bool = false,

                pub fn isPressed(self: *@This()) !bool {
                    self.called = true;
                    return true;
                }
            };

            var impl = Impl{};
            const button = Single.init(Impl, &impl);

            try lib.testing.expect(try button.isPressed());
            try lib.testing.expect(impl.called);
        }

        fn singleFromGpioButtonCallsIsPressed() !void {
            const Impl = struct {
                pub fn isPressed(_: *@This()) !bool {
                    return false;
                }
            };

            var impl = Impl{};
            const button = Single.fromGpioButton(&impl);

            try lib.testing.expect(!(try button.isPressed()));
        }

        fn groupedInitSupportsPressedButtonId() !void {
            const Impl = struct {
                called: bool = false,

                pub fn pressedButtonId(self: *@This()) !?u32 {
                    self.called = true;
                    return 3;
                }
            };

            var impl = Impl{};
            const button = Grouped.init(Impl, &impl);

            try lib.testing.expectEqual(@as(?u32, 3), try button.pressedButtonId());
            try lib.testing.expect(impl.called);
        }

        fn groupedInitSupportsPressedButton() !void {
            const Impl = struct {
                pub fn pressedButton(_: *@This()) !?u32 {
                    return 4;
                }
            };

            var impl = Impl{};
            const button = Grouped.init(Impl, &impl);

            try lib.testing.expectEqual(@as(?u32, 4), try button.pressedButton());
        }

        fn groupedFromAdcButtonUsesPressedButton() !void {
            const Impl = struct {
                pub fn pressedButton(_: *@This()) !?u32 {
                    return null;
                }
            };

            var impl = Impl{};
            const button = Grouped.fromAdcButton(&impl);

            try lib.testing.expectEqual(@as(?u32, null), try button.pressedButtonId());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.singleInitCallsIsPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.singleFromGpioButtonCallsIsPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.groupedInitSupportsPressedButtonId() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.groupedInitSupportsPressedButton() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.groupedFromAdcButtonUsesPressedButton() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

fn childType(comptime PointerType: type) type {
    return switch (@typeInfo(PointerType)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => pointer.child,
            else => @compileError("drivers.button requires a single-item pointer"),
        },
        else => @compileError("drivers.button requires a pointer"),
    };
}
