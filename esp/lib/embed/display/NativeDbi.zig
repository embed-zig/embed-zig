const embed = @import("embed_core");

const NativeDbi = @This();

pub const Config = struct {
    panel_io: *anyopaque,
    command_encoding: CommandEncoding = .plain,
};

pub const CommandEncoding = union(enum) {
    plain,
    qspi: QspiEncoding,
};

pub const QspiEncoding = struct {
    write_command_opcode: u8,
    write_color_opcode: u8,
};

const WritePhase = enum {
    command,
    color,
};

panel_io: *anyopaque,
command_encoding: CommandEncoding,

extern fn esp_embed_display_native_dbi_write_cmd(panel_io: *anyopaque, command: c_int, data: ?[*]const u8, len: usize) c_int;
extern fn esp_embed_display_native_dbi_write_data(panel_io: *anyopaque, data: ?[*]const u8, len: usize) c_int;
extern fn esp_embed_display_native_dbi_write_cmd_data(panel_io: *anyopaque, command: c_int, data: ?[*]const u8, len: usize) c_int;

pub fn init(config: Config) NativeDbi {
    return .{
        .panel_io = config.panel_io,
        .command_encoding = config.command_encoding,
    };
}

pub fn handle(self: *NativeDbi) embed.drivers.Dbi {
    return embed.drivers.Dbi.init(self);
}

pub fn writeCommand(self: *NativeDbi, command: u8, params: []const u8) embed.drivers.Dbi.Error!void {
    const ptr: ?[*]const u8 = if (params.len == 0) null else params.ptr;
    check(esp_embed_display_native_dbi_write_cmd(self.panel_io, self.encodeCommand(command, .command), ptr, params.len)) catch return error.BusError;
}

pub fn writeData(self: *NativeDbi, data: []const u8) embed.drivers.Dbi.Error!void {
    const ptr: ?[*]const u8 = if (data.len == 0) null else data.ptr;
    check(esp_embed_display_native_dbi_write_data(self.panel_io, ptr, data.len)) catch return error.BusError;
}

pub fn writeCommandData(self: *NativeDbi, command: u8, data: []const u8) embed.drivers.Dbi.Error!void {
    const ptr: ?[*]const u8 = if (data.len == 0) null else data.ptr;
    check(esp_embed_display_native_dbi_write_cmd_data(self.panel_io, self.encodeCommand(command, .color), ptr, data.len)) catch return error.BusError;
}

fn encodeCommand(self: NativeDbi, command: u8, phase: WritePhase) c_int {
    return switch (self.command_encoding) {
        .plain => command,
        .qspi => |encoding| blk: {
            const opcode = switch (phase) {
                .command => encoding.write_command_opcode,
                .color => encoding.write_color_opcode,
            };
            break :blk @intCast((@as(u32, opcode) << 24) | (@as(u32, command) << 8));
        },
    };
}

fn check(rc: c_int) !void {
    if (rc == 0) return;
    return error.NativeDbiError;
}
