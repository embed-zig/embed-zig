const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("preferences_binding.zig");

const Preferences = embed.system.Preferences;
const allocator_default = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });

pub const Provider = struct {
    allocator: esp.grt.std.mem.Allocator = allocator_default,

    pub fn init(config: Config) Provider {
        return .{
            .allocator = config.allocator orelse allocator_default,
        };
    }

    pub fn handle(self: *Provider) Preferences.Provider {
        return Preferences.Provider.init(self);
    }

    pub fn open(self: *Provider, namespace: []const u8, options: Preferences.OpenOptions) Preferences.OpenError!Preferences.Store {
        try checkInit(binding.esp_embed_preferences_init());

        if (!options.create and !options.read_only) {
            var probe_handle: binding.Handle = null;
            const probe_rc = binding.esp_embed_preferences_open(
                @ptrCast(namespace.ptr),
                namespace.len,
                true,
                &probe_handle,
            );
            try checkOpen(probe_rc);
            binding.esp_embed_preferences_close(probe_handle);
        }

        var nvs_handle: binding.Handle = null;
        const rc = binding.esp_embed_preferences_open(
            @ptrCast(namespace.ptr),
            namespace.len,
            options.read_only,
            &nvs_handle,
        );
        try checkOpen(rc);

        const store = self.allocator.create(Store) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(store);
        store.* = .{
            .allocator = self.allocator,
            .handle = nvs_handle,
        };
        return Preferences.Store.init(store);
    }

    pub const Config = struct {
        allocator: ?esp.grt.std.mem.Allocator = null,
    };
};

pub const Store = struct {
    allocator: esp.grt.std.mem.Allocator,
    handle: binding.Handle,

    pub fn get(self: *Store, key: []const u8, out: []u8) Preferences.GetError!usize {
        var len = out.len;
        const rc = binding.esp_embed_preferences_get(
            self.handle,
            @ptrCast(key.ptr),
            key.len,
            @ptrCast(out.ptr),
            &len,
        );
        try checkGet(rc);
        return len;
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) Preferences.PutError!void {
        const rc = binding.esp_embed_preferences_put(
            self.handle,
            @ptrCast(key.ptr),
            key.len,
            @ptrCast(value.ptr),
            value.len,
        );
        return checkPut(rc);
    }

    pub fn remove(self: *Store, key: []const u8) Preferences.RemoveError!void {
        const rc = binding.esp_embed_preferences_remove(
            self.handle,
            @ptrCast(key.ptr),
            key.len,
        );
        return checkRemove(rc);
    }

    pub fn contains(self: *Store, key: []const u8) bool {
        return binding.esp_embed_preferences_contains(
            self.handle,
            @ptrCast(key.ptr),
            key.len,
        );
    }

    pub fn clear(self: *Store) Preferences.ClearError!void {
        return checkClear(binding.esp_embed_preferences_clear(self.handle));
    }

    pub fn sync(self: *Store) Preferences.SyncError!void {
        return checkSync(binding.esp_embed_preferences_sync(self.handle));
    }

    pub fn deinit(self: *Store) void {
        binding.esp_embed_preferences_close(self.handle);
        self.allocator.destroy(self);
    }
};

fn checkInit(rc: i32) Preferences.OpenError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    if (rc == binding.esp_embed_preferences_err_invalid_state) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_no_free_pages) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_new_version_found) return error.Unexpected;
    return error.Unexpected;
}

fn checkOpen(rc: i32) Preferences.OpenError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidNamespace;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidNamespace;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    if (rc == binding.esp_embed_preferences_err_no_mem) return error.OutOfMemory;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkGet(rc: i32) Preferences.GetError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_handle) return error.Unexpected;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_length) return error.BufferTooSmall;
    if (rc == binding.esp_embed_preferences_err_nvs_value_too_long) return error.BufferTooSmall;
    return error.Unexpected;
}

fn checkPut(rc: i32) Preferences.PutError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    if (rc == binding.esp_embed_preferences_err_nvs_not_enough_space) return error.NoSpaceLeft;
    if (rc == binding.esp_embed_preferences_err_nvs_value_too_long) return error.ValueTooLarge;
    return error.Unexpected;
}

fn checkRemove(rc: i32) Preferences.RemoveError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_invalid_arg) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_invalid_name) return error.InvalidKey;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    if (rc == binding.esp_embed_preferences_err_not_found) return error.NotFound;
    return error.Unexpected;
}

fn checkClear(rc: i32) Preferences.ClearError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    if (rc == binding.esp_embed_preferences_err_nvs_read_only) return error.PermissionDenied;
    return error.Unexpected;
}

fn checkSync(rc: i32) Preferences.SyncError!void {
    if (rc == binding.esp_embed_preferences_ok) return;
    return error.Unexpected;
}
