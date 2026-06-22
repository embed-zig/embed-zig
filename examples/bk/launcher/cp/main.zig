const bk = @import("bk");
const armino = bk.armino;
const cp_log_forwarder = bk.cp.log_impl;

extern fn rtos_delay_milliseconds(ms: u32) c_int;

comptime {
    _ = cp_log_forwarder.write;
}

fn userAppMain(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    earlyLog("[BK CP] user app entered\r\n");
    _ = rtos_delay_milliseconds(5000);
    armino.system.bootAp() catch {
        earlyLog("[BK CP] boot AP failed\r\n");
        return;
    };
    earlyLog("[BK CP] boot AP ok\r\n");
}

export fn zig_cp_main() c_int {
    earlyLog("[BK CP] zig_cp_main entered\r\n");
    armino.system.setUserAppEntry(userAppMain);
    armino.system.init() catch {
        earlyLog("[BK CP] armino init failed\r\n");
        return 1;
    };
    earlyLog("[BK CP] armino init ok\r\n");
    return 0;
}

fn earlyLog(message: [:0]const u8) void {
    armino.system.emergencyUartWriteString(0, message);
}
