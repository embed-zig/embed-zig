const embed_core = @import("embed_core");

const cmd = embed_core.cmd;

const CliCommand = extern struct {
    name: [*:0]const u8,
    help: [*:0]const u8,
    function: *const fn (
        pcWriteBuffer: [*]u8,
        xWriteBufferLen: c_int,
        argc: c_int,
        argv: [*][*:0]u8,
    ) callconv(.c) void,
};

extern fn cli_register_command(command: *const CliCommand) c_int;

var attached_executor: ?cmd.Executor = null;

pub fn attach(executor: cmd.Executor) !void {
    if (attached_executor != null) return;
    attached_executor = executor;

    try register(&cmd_command);
    try register(&ping_command);
    try register(&version_command);
    _ = cli_register_command(&help_command);
}

fn register(command: *const CliCommand) !void {
    if (cli_register_command(command) != 0) return error.CliCommandRegisterFailed;
}

const cmd_command = CliCommand{
    .name = "cmd",
    .help = "execute an embed command line",
    .function = cmdWrapper,
};

const ping_command = CliCommand{
    .name = "ping",
    .help = "check command liveness",
    .function = directCommand,
};

const version_command = CliCommand{
    .name = "version",
    .help = "print version",
    .function = directCommand,
};

const help_command = CliCommand{
    .name = "help",
    .help = "list embed commands",
    .function = directCommand,
};

fn cmdWrapper(
    pcWriteBuffer: [*]u8,
    xWriteBufferLen: c_int,
    argc: c_int,
    argv: [*][*:0]u8,
) callconv(.c) void {
    executeArgv(pcWriteBuffer, xWriteBufferLen, 1, argc, argv);
}

fn directCommand(
    pcWriteBuffer: [*]u8,
    xWriteBufferLen: c_int,
    argc: c_int,
    argv: [*][*:0]u8,
) callconv(.c) void {
    executeArgv(pcWriteBuffer, xWriteBufferLen, 0, argc, argv);
}

fn executeArgv(
    pcWriteBuffer: [*]u8,
    xWriteBufferLen: c_int,
    skip: c_int,
    argc: c_int,
    argv: [*][*:0]u8,
) void {
    var line: [256]u8 = undefined;
    const built = buildLine(&line, skip, argc, argv) catch {
        writeStatic(pcWriteBuffer, xWriteBufferLen, "command line too long\n");
        return;
    };
    var output = BufferOutput.init(pcWriteBuffer, xWriteBufferLen);
    const out = cmd.Output.make(BufferOutput).init(&output);
    attached_executor.?.execute(built, out) catch |err| {
        output.writeAll("error: ") catch return;
        output.writeAll(@errorName(err)) catch return;
        output.writeAll("\n") catch return;
    };
}

fn buildLine(out: []u8, skip: c_int, argc: c_int, argv: [*][*:0]u8) ![]const u8 {
    var len: usize = 0;
    var index: c_int = skip;
    while (index < argc) : (index += 1) {
        const arg = cString(argv[@intCast(index)]);
        if (len != 0) {
            if (len == out.len) return error.LineTooLong;
            out[len] = ' ';
            len += 1;
        }
        if (len + arg.len > out.len) return error.LineTooLong;
        @memcpy(out[len..][0..arg.len], arg);
        len += arg.len;
    }
    return out[0..len];
}

fn cString(value: [*:0]u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn writeStatic(buffer: [*]u8, capacity: c_int, bytes: []const u8) void {
    var output = BufferOutput.init(buffer, capacity);
    output.writeAll(bytes) catch {};
}

const BufferOutput = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn init(buffer: [*]u8, capacity: c_int) BufferOutput {
        const raw_size: usize = if (capacity > 0) @intCast(capacity) else 0;
        const size = if (raw_size > 0) raw_size - 1 else 0;
        if (raw_size > 0) buffer[0] = 0;
        return .{ .buffer = buffer[0..size] };
    }

    pub fn write(self: *BufferOutput, bytes: []const u8) !usize {
        const writable = @min(bytes.len, self.buffer.len -| self.len);
        if (writable == 0) return error.BufferTooSmall;
        @memcpy(self.buffer[self.len..][0..writable], bytes[0..writable]);
        self.len += writable;
        if (self.len < self.buffer.len) self.buffer[self.len] = 0;
        if (writable != bytes.len) return error.BufferTooSmall;
        return writable;
    }

    pub fn writeAll(self: *BufferOutput, bytes: []const u8) !void {
        _ = try self.write(bytes);
    }
};
