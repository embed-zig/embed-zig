pub const EntryFn = *const fn (?*anyopaque) callconv(.c) void;

const BK_OK = 0;
const PM_BOOT_CP1_MODULE_NAME_APP = 9;
const PM_POWER_MODULE_STATE_ON = 0;

pub const Error = error{
    InitFailed,
    BootApFailed,
};

extern fn bk_init() c_int;
extern fn emergency_uart_write_string(uart_id: u32, string: [*:0]const u8) c_int;
extern fn rtos_set_user_app_entry(entry: EntryFn) void;
extern fn bk_pm_module_vote_boot_cp1_ctrl(module: c_int, power_state: c_int) c_int;

pub fn init() Error!void {
    if (bk_init() != BK_OK) return error.InitFailed;
}

pub fn setUserAppEntry(entry: EntryFn) void {
    rtos_set_user_app_entry(entry);
}

pub fn bootAp() Error!void {
    const rc = bk_pm_module_vote_boot_cp1_ctrl(PM_BOOT_CP1_MODULE_NAME_APP, PM_POWER_MODULE_STATE_ON);
    if (rc != BK_OK) return error.BootApFailed;
}

pub fn emergencyUartWriteString(uart_id: u32, string: [:0]const u8) void {
    _ = emergency_uart_write_string(uart_id, string.ptr);
}
