const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime stores_config: anytype) type {
    const StoresConfig = @TypeOf(stores_config);
    const info = @typeInfo(StoresConfig);
    if (info != .@"struct") {
        @compileError("zux.store.Builder.make expects configured stores to form a struct literal");
    }

    const fields_info = info.@"struct".fields;
    var fields: [fields_info.len]lib.builtin.Type.StructField = undefined;

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

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn builds_struct_from_store_types(testing: anytype, _: lib.mem.Allocator) !void {
            const StoreLib = struct {
                pub const builtin = lib.builtin;
            };
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const StoresTy = make(StoreLib, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            const info = @typeInfo(StoresTy).@"struct";
            try testing.expectEqual(@as(usize, 2), info.fields.len);
            try testing.expectEqualStrings("wifi", info.fields[0].name);
            try testing.expectEqualStrings("cellular", info.fields[1].name);
            try testing.expect(info.fields[0].type == Wifi);
            try testing.expect(info.fields[1].type == Cellular);
        }

        fn allows_instantiation(testing: anytype, _: lib.mem.Allocator) !void {
            const StoreLib = struct {
                pub const builtin = lib.builtin;
            };
            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };
            const StoresTy = make(StoreLib, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            const stores: StoresTy = .{
                .wifi = .{ .value = 7 },
                .cellular = .{ .enabled = true },
            };

            try testing.expectEqual(@as(u32, 7), stores.wifi.value);
            try testing.expect(stores.cellular.enabled);
        }

        fn supports_actual_usage(testing: anytype, _: lib.mem.Allocator) !void {
            const StoreLib = struct {
                pub const builtin = lib.builtin;
            };
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

            const StoresTy = make(StoreLib, .{
                .wifi = Wifi,
                .cellular = Cellular,
            });

            var stores: StoresTy = .{
                .wifi = .{ .value = 42 },
                .cellular = .{ .enabled = true },
            };

            try testing.expectEqual(@as(u32, 42), stores.wifi.get());
            try testing.expect(stores.cellular.get());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.builds_struct_from_store_types(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.allows_instantiation(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.supports_actual_usage(testing, allocator) catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
