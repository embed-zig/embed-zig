const glib = @import("glib");
const event = @import("../../event.zig");

pub fn make(comptime max_custom_events: usize) type {
    return struct {
        const Self = @This();

        event_types: [max_custom_events]type = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(self: *Self, comptime EventType: type) void {
            if (self.len >= max_custom_events) {
                @compileError("zux.Assembler exceeded max_custom_events");
            }
            validateEventType(EventType);

            inline for (0..self.len) |i| {
                const Existing = self.event_types[i];
                if (Existing == EventType) {
                    @compileError("zux.Assembler.registerCustomEvent duplicate event type: " ++ @typeName(EventType));
                }
                if (glib.std.mem.eql(u8, Existing.event_name, EventType.event_name)) {
                    @compileError("zux.Assembler.registerCustomEvent duplicate event_name '" ++ EventType.event_name ++ "'");
                }
            }

            self.event_types[self.len] = EventType;
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn Registar(comptime self: Self) type {
            return event.CustomRegistar.make(self.event_types[0..self.len]);
        }

        fn validateEventType(comptime EventType: type) void {
            const event_name: []const u8 = EventType.event_name;
            if (event_name.len == 0) {
                @compileError("zux.Assembler.registerCustomEvent event_name must not be empty");
            }
            _ = @as(*const fn (glib.std.mem.Allocator, glib.std.json.Value) anyerror!*EventType, &EventType.decodeJson);
            _ = @as(*const fn (*EventType) void, &EventType.deinit);
        }
    };
}
