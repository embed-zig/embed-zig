const glib = @import("glib");
const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Event,

pub const Code = binding.EventCode;
pub const clicked: Code = codeFromInt(binding.LV_EVENT_CLICKED);
pub const pressed: Code = codeFromInt(binding.LV_EVENT_PRESSED);
pub const released: Code = codeFromInt(binding.LV_EVENT_RELEASED);

pub fn fromRaw(handle: *binding.Event) Self {
    return .{ .handle = handle };
}

pub fn raw(self: *const Self) *binding.Event {
    return self.handle;
}

pub fn target(self: *const Self) ?*anyopaque {
    return binding.lv_event_get_target(self.handle);
}

pub fn currentTarget(self: *const Self) ?*anyopaque {
    return binding.lv_event_get_current_target(self.handle);
}

pub fn code(self: *const Self) Code {
    return binding.lv_event_get_code(self.handle);
}

pub fn param(self: *const Self) ?*anyopaque {
    return binding.lv_event_get_param(self.handle);
}

pub fn userData(self: *const Self) ?*anyopaque {
    return binding.lv_event_get_user_data(self.handle);
}

pub fn stopBubbling(self: *const Self) void {
    binding.lv_event_stop_bubbling(self.handle);
}

pub fn stopTrickling(self: *const Self) void {
    binding.lv_event_stop_trickling(self.handle);
}

pub fn stopProcessing(self: *const Self) void {
    binding.lv_event_stop_processing(self.handle);
}

pub fn registerId() u32 {
    return binding.lv_event_register_id();
}

pub fn codeFromInt(value: u32) Code {
    return switch (@typeInfo(Code)) {
        .@"enum" => @enumFromInt(value),
        else => @as(Code, @intCast(value)),
    };
}

pub fn codeName(event_code: Code) [*:0]const u8 {
    return binding.lv_event_code_get_name(event_code);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Impl = struct {
        fn raw_handle_roundtrip(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const raw_handle: *binding.Event = @ptrFromInt(1);
            const event = Self.fromRaw(raw_handle);

            try grt.std.testing.expectEqual(raw_handle, event.raw());

            _ = Self.registerId;
            _ = Self.codeFromInt;
            _ = Self.codeName;
        }

        fn codeFromInt_preserves_custom_ids(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const Helper = struct {
                fn toInt(event_code: Code) u32 {
                    return switch (@typeInfo(Code)) {
                        .@"enum" => @intFromEnum(event_code),
                        else => @as(u32, @intCast(event_code)),
                    };
                }
            };

            binding.lv_init();
            defer binding.lv_deinit();

            const custom_id = Self.registerId();
            try grt.std.testing.expectEqual(custom_id, Helper.toInt(Self.codeFromInt(custom_id)));
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

            t.run("lvgl/unit_tests/Event/raw_handle_roundtrip", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.raw_handle_roundtrip));
            t.run("lvgl/unit_tests/Event/codeFromInt_preserves_custom_ids", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.codeFromInt_preserves_custom_ids));
            return t.wait();
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
