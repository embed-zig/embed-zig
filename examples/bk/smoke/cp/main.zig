const bk = @import("bk");

const armino = bk.armino;
const cp_log_forwarder = bk.cp.log_impl;

comptime {
    _ = cp_log_forwarder.write;
}

fn userAppMain(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    armino.system.bootAp() catch {};
}

export fn zig_cp_main() c_int {
    armino.system.setUserAppEntry(userAppMain);
    armino.system.init() catch {
        return 1;
    };
    return 0;
}
