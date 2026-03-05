const esp = @import("esp");
const hal_temp = @import("hal").temp_sensor;

pub const Driver = struct {
    handle: ?esp.esp_temp_sensor.Handle = null,

    pub fn init() hal_temp.Error!Driver {
        return initRange(-10, 80);
    }

    pub fn initRange(range_min: i32, range_max: i32) hal_temp.Error!Driver {
        var self = Driver{};
        self.handle = esp.esp_temp_sensor.Handle.init(.{
            .range_min = range_min,
            .range_max = range_max,
        }) catch return error.SensorError;
        self.handle.?.enable() catch {
            self.handle.?.deinit() catch {};
            self.handle = null;
            return error.SensorError;
        };
        return self;
    }

    pub fn deinit(self: *Driver) void {
        if (self.handle) |*h| {
            h.disable() catch {};
            h.deinit() catch {};
            self.handle = null;
        }
    }

    pub fn readCelsius(self: *Driver) hal_temp.Error!f32 {
        const h = self.handle orelse return error.NotReady;
        return h.readCelsius() catch error.SensorError;
    }
};
