const embed_adapter = @import("esp_embed");
const glib = @import("glib");
const esp_grt = @import("esp_grt");
const grt = glib.runtime.make(esp_grt.runtime);

const binding = esp_grt.net.binding;
const net = embed_adapter.net;
const DriverModem = embed_adapter.drivers.Modem;

pub const Manager = struct {
    pub fn init() Manager {
        return .{};
    }

    pub fn interfaceManager(self: *Manager) net.Manager {
        return net.Manager.init(self);
    }

    pub fn listInterfaces(_: *Manager, out: []net.iface.Info) net.Error![]net.iface.Info {
        if (out.len == 0) return error.BufferTooSmall;

        var raw_buf: [16]binding.netif_info = undefined;
        const cap = @min(raw_buf.len, out.len);
        const raw_count = binding.espz_netif_list(&raw_buf, cap);
        if (raw_count > cap) return error.BufferTooSmall;

        var count: usize = 0;
        while (count < raw_count) : (count += 1) {
            out[count] = try infoFromBinding(raw_buf[count]);
        }
        return out[0..count];
    }

    pub fn getDefaultRoute(_: *Manager, family: net.AddressFamily) net.Error!?net.route.Default {
        if (family != .ipv4) return null;

        var id: usize = 0;
        try checkEsp(binding.espz_netif_get_default(&id));
        if (id == 0) return null;

        var raw_buf: [16]binding.netif_info = undefined;
        const raw_count = binding.espz_netif_list(&raw_buf, raw_buf.len);
        const count = @min(raw_count, raw_buf.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const raw = raw_buf[index];
            if (raw.id != id) continue;
            return .{
                .family = family,
                .interface_id = id,
                .gateway = if (raw.has_ipv4 != 0 and !isZero4(raw.gateway))
                    glib.net.netip.Addr.from4(raw.gateway)
                else
                    null,
                .metric = if (raw.route_prio >= 0) @intCast(raw.route_prio) else 0,
            };
        }

        return .{
            .family = family,
            .interface_id = id,
        };
    }

    pub fn setDefaultRoute(_: *Manager, default: net.route.Default) net.Error!void {
        if (default.family != .ipv4) return error.InvalidRoute;
        try checkEsp(binding.espz_netif_set_default(default.interface_id));
    }
};

pub const ModemPpp = struct {
    const Self = @This();
    const AtomicBool = grt.std.atomic.Value(bool);
    const read_timeout = 200 * glib.time.duration.MilliSecond;
    const read_buf_size = 512;

    pub const Config = struct {
        allocator: glib.std.mem.Allocator,
        modem: DriverModem,
        read_task_options: glib.task.Options = .{
            .min_stack_size = 8 * 1024,
        },
    };

    allocator: ?glib.std.mem.Allocator = null,
    modem: ?DriverModem = null,
    handle: ?*binding.modem_ppp = null,
    read_task: ?grt.task.Handle = null,
    stop_read: AtomicBool = AtomicBool.init(false),
    active: bool = false,

    pub fn ensureInterface(self: *Self, allocator: glib.std.mem.Allocator) !void {
        self.allocator = allocator;
        if (self.handle != null) return;

        const handle = binding.espz_modem_ppp_create(@ptrCast(self)) orelse return error.Unsupported;
        errdefer binding.espz_modem_ppp_destroy(handle);
        self.handle = handle;
    }

    pub fn start(self: *Self, config: Config) !void {
        self.allocator = config.allocator;
        self.modem = config.modem;
        self.stop_read.store(false, .release);

        try self.ensureInterface(config.allocator);
        const handle = self.handle.?;
        try checkEsp(binding.espz_modem_ppp_start(handle));
        errdefer checkEsp(binding.espz_modem_ppp_stop(handle)) catch {};

        if (self.read_task == null) {
            self.read_task = try grt.task.go(
                "net/modem_ppp_rx",
                config.read_task_options,
                glib.task.Routine.init(self, readLoop),
            );
        }
        self.active = true;
    }

    pub fn stop(self: *Self) void {
        if (!self.active and self.read_task == null) return;
        self.stop_read.store(true, .release);
        if (self.modem) |modem| {
            modem.setDataReadDeadline(grt.time.instant.now());
        }
        if (self.read_task) |task| {
            task.join();
            self.read_task = null;
        }
        if (self.handle) |handle| checkEsp(binding.espz_modem_ppp_stop(handle)) catch {};
        self.modem = null;
        self.active = false;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.handle) |handle| {
            binding.espz_modem_ppp_destroy(handle);
            self.handle = null;
        }
        self.allocator = null;
    }

    pub fn setDefaultRoute(self: *Self) net.Error!void {
        const handle = self.handle orelse return error.InvalidInterface;
        try checkEsp(binding.espz_modem_ppp_set_default(handle));
    }

    pub fn interfaceId(self: *Self) usize {
        const handle = self.handle orelse return 0;
        return binding.espz_modem_ppp_netif_id(handle);
    }

    pub fn ipv4(self: *Self) ?glib.net.netip.Addr {
        const id = self.interfaceId();
        if (id == 0) return null;

        var raw_buf: [16]binding.netif_info = undefined;
        const raw_count = binding.espz_netif_list(&raw_buf, raw_buf.len);
        const count = @min(raw_count, raw_buf.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const raw = raw_buf[index];
            if (raw.id != id or raw.has_ipv4 == 0 or isZero4(raw.ipv4)) continue;
            return glib.net.netip.Addr.from4(raw.ipv4);
        }
        return null;
    }

    fn readLoop(self: *Self) void {
        var buf: [read_buf_size]u8 = undefined;
        while (!self.stop_read.load(.acquire)) {
            const modem = self.modem orelse break;
            modem.setDataReadDeadline(grt.time.instant.now() + read_timeout);
            const n = modem.dataRead(&buf) catch |err| switch (err) {
                error.TimedOut => continue,
                error.EndOfStream, error.ConnectionReset, error.Unsupported => break,
                else => continue,
            };
            if (n == 0) continue;
            if (self.handle) |handle| {
                checkEsp(binding.espz_modem_ppp_input(handle, buf[0..n].ptr, n)) catch {};
            }
        }
    }
};

export fn espz_modem_ppp_write(ctx: ?*anyopaque, data: ?*const anyopaque, len: usize, written: *usize) c_int {
    const self: *ModemPpp = @ptrCast(@alignCast(ctx orelse return -1));
    const modem = self.modem orelse return -1;
    const ptr: [*]const u8 = @ptrCast(data orelse return -1);
    const bytes = ptr[0..len];
    const n = modem.dataWrite(bytes) catch return -1;
    written.* = n;
    return 0;
}

fn infoFromBinding(raw: binding.netif_info) net.Error!net.iface.Info {
    const name = raw.name[0..@min(raw.name_len, raw.name.len)];
    var info = try net.iface.Info.init(raw.id, name);
    info.flags.up = raw.up != 0;
    info.flags.running = raw.up != 0;
    info.flags.default = raw.is_default != 0;
    if (raw.has_ipv4 != 0) {
        try info.appendAddress(.{
            .family = .ipv4,
            .address = glib.net.netip.Addr.from4(raw.ipv4),
            .prefix_len = prefixLen4(raw.netmask),
        });
    }
    return info;
}

fn checkEsp(rc: c_int) net.Error!void {
    if (rc == 0) return;
    if (rc == -2) return error.InvalidInterface;
    if (rc == -1) return error.Unsupported;
    return error.Unexpected;
}

fn isZero4(bytes: [4]u8) bool {
    return bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0;
}

fn prefixLen4(bytes: [4]u8) u8 {
    var prefix: u8 = 0;
    for (bytes) |byte| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if ((byte & (@as(u8, 0x80) >> @intCast(bit))) == 0) return prefix;
            prefix += 1;
        }
    }
    return prefix;
}
