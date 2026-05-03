pub fn make(comptime AppType: type) type {
    const InitConfig = AppType.InitConfig;

    return struct {
        const UserStoryConfigFactory = @This();

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const Instance = struct {
            ptr: *anyopaque,
            vtable: *const InstanceVTable,

            pub const InstanceVTable = struct {
                config: *const fn (ptr: *anyopaque) InitConfig,
                deinit: *const fn (ptr: *anyopaque) void,
            };

            pub fn wrap(pointer: anytype) Instance {
                const Ptr = @TypeOf(pointer);
                const info = @typeInfo(Ptr);
                if (info != .pointer or info.pointer.size != .one) {
                    @compileError("UserStoryConfigFactory.Instance.wrap expects a single-item pointer");
                }

                const Impl = info.pointer.child;
                comptime {
                    _ = @as(*const fn (*Impl) InitConfig, &Impl.config);
                    _ = @as(*const fn (*Impl) void, &Impl.deinit);
                }

                const gen = struct {
                    fn configFn(ptr: *anyopaque) InitConfig {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.config();
                    }

                    fn deinitFn(ptr: *anyopaque) void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        self.deinit();
                    }

                    const vtable = InstanceVTable{
                        .config = configFn,
                        .deinit = deinitFn,
                    };
                };

                return .{
                    .ptr = pointer,
                    .vtable = &gen.vtable,
                };
            }

            pub fn config(self: Instance) InitConfig {
                return self.vtable.config(self.ptr);
            }

            pub fn deinit(self: Instance) void {
                self.vtable.deinit(self.ptr);
            }
        };

        pub const VTable = struct {
            make: *const fn (ptr: *anyopaque, init_config: InitConfig) anyerror!Instance,
        };

        pub fn wrap(pointer: anytype) UserStoryConfigFactory {
            const Ptr = @TypeOf(pointer);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one) {
                @compileError("UserStoryConfigFactory.wrap expects a single-item pointer");
            }

            const Impl = info.pointer.child;
            comptime {
                _ = @as(*const fn (*Impl, InitConfig) anyerror!*Impl.Instance, &Impl.make);
            }

            const gen = struct {
                fn makeFn(ptr: *anyopaque, init_config: InitConfig) anyerror!Instance {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    const instance = try self.make(init_config);
                    return Instance.wrap(instance);
                }

                const vtable = VTable{
                    .make = makeFn,
                };
            };

            return .{
                .ptr = pointer,
                .vtable = &gen.vtable,
            };
        }

        pub fn makeInstance(self: UserStoryConfigFactory, init_config: InitConfig) !Instance {
            return self.vtable.make(self.ptr, init_config);
        }
    };
}
