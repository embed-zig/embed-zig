const esp = @import("esp");
const hal_kvs = @import("hal").kvs;

const nvs = esp.nvs_flash;

pub const Driver = struct {
    ns: nvs.Namespace,

    pub fn init(namespace: []const u8) hal_kvs.KvsError!Driver {
        nvs.init() catch |err| {
            switch (err) {
                error.StorageFull, error.SchemaMismatch => {
                    nvs.erase() catch return error.WriteError;
                    nvs.init() catch return error.WriteError;
                },
                else => return error.WriteError,
            }
        };

        const ns = nvs.Namespace.open(namespace) catch |err| {
            return switch (err) {
                error.InvalidArgument => error.InvalidKey,
                else => error.WriteError,
            };
        };
        return .{ .ns = ns };
    }

    pub fn deinit(self: *Driver) void {
        self.ns.close();
        nvs.deinit() catch {};
    }

    pub fn getU32(self: *Driver, key: []const u8) hal_kvs.KvsError!u32 {
        return self.ns.getU32(key) catch |err| mapReadError(err);
    }

    pub fn setU32(self: *Driver, key: []const u8, value: u32) hal_kvs.KvsError!void {
        self.ns.setU32(key, value) catch |err| return mapWriteError(err);
    }

    pub fn getI32(self: *Driver, key: []const u8) hal_kvs.KvsError!i32 {
        return self.ns.getI32(key) catch |err| mapReadError(err);
    }

    pub fn setI32(self: *Driver, key: []const u8, value: i32) hal_kvs.KvsError!void {
        self.ns.setI32(key, value) catch |err| return mapWriteError(err);
    }

    pub fn getString(self: *Driver, key: []const u8, out: []u8) hal_kvs.KvsError![]const u8 {
        return self.ns.getString(key, out) catch |err| mapReadError(err);
    }

    pub fn setString(self: *Driver, key: []const u8, value: []const u8) hal_kvs.KvsError!void {
        self.ns.setString(key, value) catch |err| return mapWriteError(err);
    }

    pub fn erase(self: *Driver, key: []const u8) hal_kvs.KvsError!void {
        self.ns.erase(key) catch |err| return mapWriteError(err);
    }

    pub fn eraseAll(self: *Driver) hal_kvs.KvsError!void {
        self.ns.eraseAll() catch |err| return mapWriteError(err);
    }

    pub fn commit(self: *Driver) hal_kvs.KvsError!void {
        self.ns.commit() catch |err| return mapWriteError(err);
    }
};

fn mapReadError(err: anyerror) hal_kvs.KvsError {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.BufferTooSmall => error.BufferTooSmall,
        error.InvalidArgument => error.InvalidKey,
        else => error.ReadError,
    };
}

fn mapWriteError(err: anyerror) hal_kvs.KvsError {
    return switch (err) {
        error.InvalidArgument => error.InvalidKey,
        error.StorageFull => error.StorageFull,
        else => error.WriteError,
    };
}
