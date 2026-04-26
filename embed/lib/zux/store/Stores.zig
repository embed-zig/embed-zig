const glib = @import("glib");

pub fn make(comptime grt: type, comptime stores_config: anytype) type {
    const StoresConfig = @TypeOf(stores_config);
    const info = @typeInfo(StoresConfig);
    if (info != .@"struct") {
        @compileError("zux.store.Builder.make expects configured stores to form a struct literal");
    }

    const fields_info = info.@"struct".fields;
    var fields: [fields_info.len]grt.std.builtin.Type.StructField = undefined;

    inline for (fields_info, 0..) |field, i| {
        const StoreType = @field(stores_config, field.name);
        if (@TypeOf(StoreType) != type) {
            @compileError("zux.store.Builder.make expects configured store '" ++ field.name ++ "' to be a type");
        }

        fields[i] = .{
            .name = field.name,
            .type = StoreType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(StoreType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn builds_struct_from_store_types(_: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const StoresTy = make(grt, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            const info = @typeInfo(StoresTy).@"struct";
            try grt.std.testing.expectEqual(@as(usize, 2), info.fields.len);
            try grt.std.testing.expectEqualStrings("wifi", info.fields[0].name);
            try grt.std.testing.expectEqualStrings("cellular", info.fields[1].name);
            try grt.std.testing.expect(info.fields[0].type == Wifi);
            try grt.std.testing.expect(info.fields[1].type == Cellular);
        }

        fn allows_instantiation(_: glib.std.mem.Allocator) !void {
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };
            const StoresTy = make(grt, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            const stores: StoresTy = .{
                .wifi = .{ .value = 7 },
                .cellular = .{ .enabled = true },
            };

            try grt.std.testing.expectEqual(@as(u32, 7), stores.wifi.value);
            try grt.std.testing.expect(stores.cellular.enabled);
        }

        fn supports_actual_usage(_: glib.std.mem.Allocator) !void {
            const Wifi = struct {
                value: u32,

                pub fn get(self: *@This()) u32 {
                    return self.value;
                }
            };
            const Cellular = struct {
                enabled: bool,

                pub fn get(self: *@This()) bool {
                    return self.enabled;
                }
            };

            const StoresTy = make(grt, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            var stores: StoresTy = .{
                .wifi = .{ .value = 42 },
                .cellular = .{ .enabled = true },
            };

            try grt.std.testing.expectEqual(@as(u32, 42), stores.wifi.get());
            try grt.std.testing.expect(stores.cellular.get());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.builds_struct_from_store_types(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.allows_instantiation(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.supports_actual_usage(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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
