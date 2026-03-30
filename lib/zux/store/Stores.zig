pub fn make(comptime lib: type, comptime stores_config: anytype) type {
    const StoresConfig = @TypeOf(stores_config);
    const info = @typeInfo(StoresConfig);
    if (info != .@"struct") {
        @compileError("zux.Store.make expects config.stores to be a struct literal");
    }

    const fields_info = info.@"struct".fields;
    var fields: [fields_info.len]lib.builtin.Type.StructField = undefined;

    inline for (fields_info, 0..) |field, i| {
        const StoreType = @field(stores_config, field.name);
        if (@TypeOf(StoreType) != type) {
            @compileError("zux.Store.make expects config.stores." ++ field.name ++ " to be a type");
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

test "zux/unit_tests/store/Stores/builds_struct_from_store_types" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
    };
    const Wifi = struct { value: u32 };
    const Cellular = struct { enabled: bool };

    const Stores = make(TestLib, .{
        .wifi = Wifi,
        .cellular = Cellular,
    });

    const info = @typeInfo(Stores).@"struct";
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);
    try std.testing.expect(std.mem.eql(u8, "wifi", info.fields[0].name));
    try std.testing.expect(std.mem.eql(u8, "cellular", info.fields[1].name));
    try std.testing.expect(info.fields[0].type == Wifi);
    try std.testing.expect(info.fields[1].type == Cellular);
}

test "zux/unit_tests/store/Stores/allows_instantiation" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
    };
    const Wifi = struct { value: u32 };
    const Cellular = struct { enabled: bool };
    const Stores = make(TestLib, .{
        .wifi = Wifi,
        .cellular = Cellular,
    });

    const stores: Stores = .{
        .wifi = .{ .value = 7 },
        .cellular = .{ .enabled = true },
    };

    try std.testing.expectEqual(@as(u32, 7), stores.wifi.value);
    try std.testing.expect(stores.cellular.enabled);
}

test "zux/unit_tests/store/Stores/supports_actual_usage" {
    const std = @import("std");
    const TestLib = struct {
        pub const builtin = std.builtin;
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

    const Stores = make(TestLib, .{
        .wifi = Wifi,
        .cellular = Cellular,
    });

    var stores: Stores = .{
        .wifi = .{ .value = 42 },
        .cellular = .{ .enabled = true },
    };

    try std.testing.expectEqual(@as(u32, 42), stores.wifi.get());
    try std.testing.expect(stores.cellular.get());
}
