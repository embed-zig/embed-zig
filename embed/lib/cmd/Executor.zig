const glib = @import("glib");

const Command = @import("Command.zig");
const Output = @import("Output.zig");
const Parser = @import("Parser.zig");

const Executor = @This();

ctx: ?*anyopaque,
vtable: *const VTable,

pub const Error = error{
    EmptyCommand,
    UnknownCommand,
    DuplicateCommand,
};

pub const VTable = struct {
    addCommand: *const fn (ctx: ?*anyopaque, command: Command) anyerror!void,
    execute: *const fn (ctx: ?*anyopaque, line: []const u8, out: Output) anyerror!void,
    deinit: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub fn addCommand(self: Executor, command: Command) !void {
    return self.vtable.addCommand(self.ctx, command);
}

pub fn execute(self: Executor, line: []const u8, out: Output) !void {
    return self.vtable.execute(self.ctx, line, out);
}

pub fn deinit(self: Executor) void {
    if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ctx);
}

pub fn make(comptime Impl: type) type {
    return struct {
        pub fn init(impl: *Impl) Executor {
            return .{
                .ctx = impl,
                .vtable = &.{
                    .addCommand = vtableAddCommand,
                    .execute = vtableExecute,
                    .deinit = if (@hasDecl(Impl, "deinit")) vtableDeinit else null,
                },
            };
        }

        fn vtableAddCommand(ctx: ?*anyopaque, command: Command) anyerror!void {
            const impl: *Impl = @ptrCast(@alignCast(ctx.?));
            return impl.addCommand(command);
        }

        fn vtableExecute(ctx: ?*anyopaque, line: []const u8, out: Output) anyerror!void {
            const impl: *Impl = @ptrCast(@alignCast(ctx.?));
            return impl.execute(line, out);
        }

        fn vtableDeinit(ctx: ?*anyopaque) void {
            const impl: *Impl = @ptrCast(@alignCast(ctx.?));
            impl.deinit();
        }
    };
}

pub const Registry = struct {
    allocator: glib.std.mem.Allocator,
    commands: glib.std.ArrayList(Command) = .empty,
    version: []const u8 = "unsupported",

    const Self = @This();

    pub fn init(allocator: glib.std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn executor(self: *Self) Executor {
        return Executor.make(Self).init(self);
    }

    pub fn addCommand(self: *Self, command: Command) !void {
        if (command.name.len == 0) return Error.EmptyCommand;
        if (self.find(command.name) != null) return Error.DuplicateCommand;
        try self.commands.append(self.allocator, command);
    }

    pub fn execute(self: *Self, line: []const u8, out: Output) !void {
        const parsed = Parser.parseLine(line) orelse return Error.EmptyCommand;
        const command = self.find(parsed.name) orelse return Error.UnknownCommand;
        return command.handler(command.ctx, parsed.args, out);
    }

    pub fn commandList(self: *const Self) []const Command {
        return self.commands.items;
    }

    pub fn setVersion(self: *Self, version: []const u8) void {
        self.version = version;
    }

    pub fn getVersion(self: *const Self) []const u8 {
        return self.version;
    }

    fn find(self: *const Self, name: []const u8) ?Command {
        for (self.commands.items) |command| {
            if (glib.std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};
