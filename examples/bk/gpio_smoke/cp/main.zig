const bk = @import("bk");
const armino = bk.armino;

extern fn rtos_delay_milliseconds(ms: u32) c_int;

fn userAppMain(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    earlyLog("[BK GPIO CP] user app entered\r\n");
    _ = rtos_delay_milliseconds(5000);
    armino.system.bootAp() catch {
        earlyLog("[BK GPIO CP] boot AP failed\r\n");
        return;
    };
    earlyLog("[BK GPIO CP] boot AP ok\r\n");
}

export fn zig_cp_main() c_int {
    earlyLog("[BK GPIO CP] zig_cp_main entered\r\n");
    armino.system.setUserAppEntry(userAppMain);
    armino.system.init() catch {
        earlyLog("[BK GPIO CP] armino init failed\r\n");
        return 1;
    };
    earlyLog("[BK GPIO CP] armino init ok\r\n");
    return 0;
}

fn earlyLog(message: [:0]const u8) void {
    armino.system.emergencyUartWriteString(0, message);
}
