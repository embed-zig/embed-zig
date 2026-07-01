//! Gpio — non-owning type-erased single-pin GPIO interface.

const glib = @import("glib");

const Gpio = @This();

pub const Pca9557 = @import("gpio/pca9557.zig");
pub const Tca9554 = @import("gpio/tca9554.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = anyerror;

pub const Direction = enum(u1) {
    output = 0,
    input = 1,
};

pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

pub const Edge = enum {
    rising,
    falling,
    both,
    low_level,
    high_level,
};

pub const Event = struct {
    edge: Edge,
    level: Level,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, event: Event) void;

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque) Error!Level,
    write: *const fn (ptr: *anyopaque, level: Level) Error!void,
    setDirection: *const fn (ptr: *anyopaque, direction: Direction) Error!void,
    configureInterrupt: *const fn (ptr: *anyopaque, edge: Edge) Error!void = defaultConfigureInterrupt,
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void = defaultSetEventCallback,
    clearEventCallback: *const fn (ptr: *anyopaque) void = defaultClearEventCallback,
};

pub fn read(self: Gpio) Error!Level {
    return self.vtable.read(self.ptr);
}

pub fn write(self: Gpio, level: Level) Error!void {
    try self.vtable.write(self.ptr, level);
}

pub fn setDirection(self: Gpio, direction: Direction) Error!void {
    try self.vtable.setDirection(self.ptr, direction);
}

pub fn setInput(self: Gpio) Error!void {
    try self.setDirection(.input);
}

pub fn setOutput(self: Gpio) Error!void {
    try self.setDirection(.output);
}

pub fn setHigh(self: Gpio) Error!void {
    try self.write(.high);
}

pub fn setLow(self: Gpio) Error!void {
    try self.write(.low);
}

pub fn configureInterrupt(self: Gpio, edge: Edge) Error!void {
    try self.vtable.configureInterrupt(self.ptr, edge);
}

pub fn setEventCallback(self: Gpio, ctx: *const anyopaque, emit_fn: CallbackFn) void {
    self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: Gpio) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn init(pointer: anytype) Gpio {
    const Impl = childType(@TypeOf(pointer));

    comptime {
        _ = @as(*const fn (*Impl) Error!Level, &Impl.read);
        _ = @as(*const fn (*Impl, Level) Error!void, &Impl.write);
        _ = @as(*const fn (*Impl, Direction) Error!void, &Impl.setDirection);
    }

    const gen = struct {
        fn readFn(ptr: *anyopaque) Error!Level {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read();
        }

        fn writeFn(ptr: *anyopaque, level: Level) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.write(level);
        }

        fn setDirectionFn(ptr: *anyopaque, direction: Direction) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.setDirection(direction);
        }

        fn configureInterruptFn(ptr: *anyopaque, edge: Edge) Error!void {
            if (comptime !@hasDecl(Impl, "configureInterrupt")) {
                return defaultConfigureInterrupt(ptr, edge);
            }
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.configureInterrupt(edge);
        }

        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            if (comptime !@hasDecl(Impl, "setEventCallback")) {
                defaultSetEventCallback(ptr, ctx, emit_fn);
                return;
            }
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            if (comptime !@hasDecl(Impl, "clearEventCallback")) {
                defaultClearEventCallback(ptr);
                return;
            }
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .read = readFn,
            .write = writeFn,
            .setDirection = setDirectionFn,
            .configureInterrupt = configureInterruptFn,
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn fromTca9554(pointer: anytype, comptime pin: anytype) Gpio {
    const Impl = childType(@TypeOf(pointer));

    const gen = struct {
        fn readFn(ptr: *anyopaque) Error!Level {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return try self.read(pin);
        }

        fn writeFn(ptr: *anyopaque, level: Level) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.write(pin, switch (level) {
                .high => .high,
                .low => .low,
            });
        }

        fn setDirectionFn(ptr: *anyopaque, direction: Direction) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.setDirection(pin, switch (direction) {
                .output => .output,
                .input => .input,
            });
        }

        const vtable = VTable{
            .read = readFn,
            .write = writeFn,
            .setDirection = setDirectionFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn fromPca9557(pointer: anytype, comptime pin: anytype) Gpio {
    const Impl = childType(@TypeOf(pointer));

    const gen = struct {
        fn readFn(ptr: *anyopaque) Error!Level {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return try self.read(pin);
        }

        fn writeFn(ptr: *anyopaque, level: Level) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.write(pin, switch (level) {
                .high => .high,
                .low => .low,
            });
        }

        fn setDirectionFn(ptr: *anyopaque, direction: Direction) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            try self.setDirection(pin, switch (direction) {
                .output => .output,
                .input => .input,
            });
        }

        const vtable = VTable{
            .read = readFn,
            .write = writeFn,
            .setDirection = setDirectionFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesRead() !void {
            const Fake = struct {
                level: Level = .high,

                fn read(self: *@This()) Error!Level {
                    return self.level;
                }

                fn write(self: *@This(), level: Level) Error!void {
                    self.level = level;
                }

                fn setDirection(_: *@This(), _: Direction) Error!void {}
            };

            var fake = Fake{};
            const gpio = Gpio.init(&fake);
            try grt.std.testing.expectEqual(Level.high, try gpio.read());
        }

        fn propagatesBackendErrors() !void {
            const Fake = struct {
                fail: bool = false,

                fn read(self: *@This()) Error!Level {
                    if (self.fail) return error.Timeout;
                    return .low;
                }

                fn write(_: *@This(), _: Level) Error!void {}

                fn setDirection(_: *@This(), _: Direction) Error!void {}
            };

            var fake = Fake{ .fail = true };
            const gpio = Gpio.init(&fake);
            try grt.std.testing.expectError(error.Timeout, gpio.read());
        }

        fn writeAndDirectionDispatch() !void {
            const Fake = struct {
                last_level: Level = .low,
                last_direction: Direction = .input,

                fn read(self: *@This()) Error!Level {
                    return self.last_level;
                }

                fn write(self: *@This(), level: Level) Error!void {
                    self.last_level = level;
                }

                fn setDirection(self: *@This(), direction: Direction) Error!void {
                    self.last_direction = direction;
                }
            };

            var fake = Fake{};
            const gpio = Gpio.init(&fake);
            try gpio.setOutput();
            try gpio.setHigh();
            try grt.std.testing.expectEqual(Level.high, fake.last_level);
            try grt.std.testing.expectEqual(Direction.output, fake.last_direction);
        }

        fn fromTca9554AdaptsChipMethods() !void {
            const Expander = struct {
                pub const Pin = enum { pin3 };

                last_direction: ?Direction = null,
                last_level: ?Level = null,
                level: Level = .low,

                fn read(self: *@This(), comptime actual_pin: Pin) Error!Level {
                    _ = actual_pin;
                    return self.level;
                }

                fn write(self: *@This(), comptime actual_pin: Pin, level: Level) Error!void {
                    _ = actual_pin;
                    self.last_level = level;
                }

                fn setDirection(self: *@This(), comptime actual_pin: Pin, direction: Direction) Error!void {
                    _ = actual_pin;
                    self.last_direction = direction;
                }
            };

            var expander = Expander{ .level = .high };
            const gpio = Gpio.fromTca9554(&expander, .pin3);
            try grt.std.testing.expectEqual(Level.high, try gpio.read());
            try gpio.setLow();
            try gpio.setInput();
            try grt.std.testing.expectEqual(@as(?Level, .low), expander.last_level);
            try grt.std.testing.expectEqual(@as(?Direction, .input), expander.last_direction);
        }

        fn fromPca9557AdaptsChipMethods() !void {
            const Expander = struct {
                pub const Pin = enum { pin1 };

                last_direction: ?Direction = null,
                last_level: ?Level = null,
                level: Level = .low,

                fn read(self: *@This(), comptime actual_pin: Pin) Error!Level {
                    _ = actual_pin;
                    return self.level;
                }

                fn write(self: *@This(), comptime actual_pin: Pin, level: Level) Error!void {
                    _ = actual_pin;
                    self.last_level = level;
                }

                fn setDirection(self: *@This(), comptime actual_pin: Pin, direction: Direction) Error!void {
                    _ = actual_pin;
                    self.last_direction = direction;
                }
            };

            var expander = Expander{ .level = .high };
            const gpio = Gpio.fromPca9557(&expander, .pin1);
            try grt.std.testing.expectEqual(Level.high, try gpio.read());
            try gpio.setLow();
            try gpio.setInput();
            try grt.std.testing.expectEqual(@as(?Level, .low), expander.last_level);
            try grt.std.testing.expectEqual(@as(?Direction, .input), expander.last_direction);
        }

        fn defaultInterruptSupportIsUnsupported() !void {
            const Fake = struct {
                fn read(_: *@This()) Error!Level {
                    return .low;
                }

                fn write(_: *@This(), _: Level) Error!void {}

                fn setDirection(_: *@This(), _: Direction) Error!void {}
            };

            var fake = Fake{};
            const gpio = Gpio.init(&fake);
            try grt.std.testing.expectError(error.Unsupported, gpio.configureInterrupt(.rising));
            gpio.setEventCallback(@ptrFromInt(@as(usize, 1)), struct {
                fn callback(_: *const anyopaque, _: Event) void {}
            }.callback);
            gpio.clearEventCallback();
        }

        fn forwardsInterruptAndCallbackSupport() !void {
            const Fake = struct {
                configured_edge: ?Edge = null,
                callback_ctx: ?*const anyopaque = null,
                callback_fn: ?CallbackFn = null,
                clear_count: usize = 0,

                fn read(_: *@This()) Error!Level {
                    return .low;
                }

                fn write(_: *@This(), _: Level) Error!void {}

                fn setDirection(_: *@This(), _: Direction) Error!void {}

                fn configureInterrupt(self: *@This(), edge: Edge) Error!void {
                    self.configured_edge = edge;
                }

                fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.callback_ctx = ctx;
                    self.callback_fn = emit_fn;
                }

                fn clearEventCallback(self: *@This()) void {
                    self.callback_ctx = null;
                    self.callback_fn = null;
                    self.clear_count += 1;
                }

                fn emit(self: *@This(), event: Event) void {
                    const ctx = self.callback_ctx orelse return;
                    const emit_fn = self.callback_fn orelse return;
                    emit_fn(ctx, event);
                }
            };

            const Sink = struct {
                count: usize = 0,
                last_event: ?Event = null,

                fn callback(ctx: *const anyopaque, event: Event) void {
                    const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
                    self.count += 1;
                    self.last_event = event;
                }
            };

            var fake = Fake{};
            var sink = Sink{};
            const gpio = Gpio.init(&fake);

            try gpio.configureInterrupt(.both);
            gpio.setEventCallback(@ptrCast(&sink), Sink.callback);
            fake.emit(.{ .edge = .rising, .level = .high });
            gpio.clearEventCallback();

            try grt.std.testing.expectEqual(@as(?Edge, .both), fake.configured_edge);
            try grt.std.testing.expectEqual(@as(usize, 1), sink.count);
            try grt.std.testing.expectEqual(Edge.rising, sink.last_event.?.edge);
            try grt.std.testing.expectEqual(Level.high, sink.last_event.?.level);
            try grt.std.testing.expectEqual(@as(usize, 1), fake.clear_count);
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
                TestCase.dispatchesRead,
                TestCase.propagatesBackendErrors,
                TestCase.writeAndDirectionDispatch,
                TestCase.fromTca9554AdaptsChipMethods,
                TestCase.fromPca9557AdaptsChipMethods,
                TestCase.defaultInterruptSupportIsUnsupported,
                TestCase.forwardsInterruptAndCallbackSupport,
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

fn defaultConfigureInterrupt(_: *anyopaque, _: Edge) Error!void {
    return error.Unsupported;
}

fn defaultSetEventCallback(_: *anyopaque, _: *const anyopaque, _: CallbackFn) void {}

fn defaultClearEventCallback(_: *anyopaque) void {}

fn childType(comptime PointerType: type) type {
    return switch (@typeInfo(PointerType)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => pointer.child,
            else => @compileError("Gpio.init expects a single-item pointer"),
        },
        else => @compileError("Gpio.init expects a pointer"),
    };
}
