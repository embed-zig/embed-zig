const bt = @import("bt");
const drivers = @import("drivers");
const ledstrip = @import("ledstrip");
const SpecType = @import("Spec.zig");

pub const State = enum {
    uninitialized,
    powered_off,
    powered_on,
    started,
    light_sleep,
    deep_sleep,
};

pub const Error = error{
    Unsupported,
    NotFound,
    InvalidState,
};

pub fn make(comptime grt: type, comptime spec: SpecType) type {
    _ = grt;

    const has_audio = spec.Mic != void and spec.Speaker != void and spec.AudioSystem != void;

    return struct {
        const Board = @This();

        pub const Mic = spec.Mic;
        pub const Speaker = spec.Speaker;
        pub const AudioSystem = spec.AudioSystem;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            deinit: ?*const fn (ptr: *anyopaque) void = null,
            state: ?*const fn (ptr: *anyopaque) State = null,
            powerOn: ?*const fn (ptr: *anyopaque) anyerror!void = null,
            start: ?*const fn (ptr: *anyopaque) anyerror!void = null,
            enterLightSleep: ?*const fn (ptr: *anyopaque) anyerror!void = null,
            enterDeepSleep: ?*const fn (ptr: *anyopaque) anyerror!void = null,

            singleButton: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.button.Single = null,
            groupedButton: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.button.Grouped = null,
            imu: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.imu = null,
            ledStrip: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!ledstrip.LedStrip = null,
            modem: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.Modem = null,
            nfc: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.nfc.Reader = null,
            touch: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.Touch = null,
            wifiSta: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.wifi.Sta = null,
            wifiAp: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!drivers.wifi.Ap = null,
            btCentral: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!bt.Central = null,
            btPeripheral: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!bt.Peripheral = null,
            mic: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!Mic = null,
            speaker: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!Speaker = null,
            audioSystem: ?*const fn (ptr: *anyopaque, label: []const u8) anyerror!*AudioSystem = null,
        };

        pub fn init(comptime Impl: type, impl: *Impl) Board {
            const gen = struct {
                fn deinitFn(ptr: *anyopaque) void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "deinit")) {
                        self.deinit();
                    }
                }

                fn stateFn(ptr: *anyopaque) State {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "state")) {
                        return self.state();
                    }
                    return .uninitialized;
                }

                fn powerOnFn(ptr: *anyopaque) anyerror!void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "powerOn")) {
                        return self.powerOn();
                    }
                    return error.Unsupported;
                }

                fn startFn(ptr: *anyopaque) anyerror!void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "start")) {
                        return self.start();
                    }
                    return error.Unsupported;
                }

                fn enterLightSleepFn(ptr: *anyopaque) anyerror!void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "enterLightSleep")) {
                        return self.enterLightSleep();
                    }
                    return error.Unsupported;
                }

                fn enterDeepSleepFn(ptr: *anyopaque) anyerror!void {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "enterDeepSleep")) {
                        return self.enterDeepSleep();
                    }
                    return error.Unsupported;
                }

                fn singleButtonFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.button.Single {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "singleButton")) {
                        return self.singleButton(label);
                    }
                    return error.Unsupported;
                }

                fn groupedButtonFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.button.Grouped {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "groupedButton")) {
                        return self.groupedButton(label);
                    }
                    return error.Unsupported;
                }

                fn imuFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.imu {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "imu")) {
                        return self.imu(label);
                    }
                    return error.Unsupported;
                }

                fn ledStripFn(ptr: *anyopaque, label: []const u8) anyerror!ledstrip.LedStrip {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "ledStrip")) {
                        return self.ledStrip(label);
                    }
                    return error.Unsupported;
                }

                fn modemFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.Modem {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "modem")) {
                        return self.modem(label);
                    }
                    return error.Unsupported;
                }

                fn nfcFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.nfc.Reader {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "nfc")) {
                        return self.nfc(label);
                    }
                    return error.Unsupported;
                }

                fn touchFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.Touch {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "touch")) {
                        return self.touch(label);
                    }
                    return error.Unsupported;
                }

                fn wifiStaFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.wifi.Sta {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "wifiSta")) {
                        return self.wifiSta(label);
                    }
                    return error.Unsupported;
                }

                fn wifiApFn(ptr: *anyopaque, label: []const u8) anyerror!drivers.wifi.Ap {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "wifiAp")) {
                        return self.wifiAp(label);
                    }
                    return error.Unsupported;
                }

                fn btCentralFn(ptr: *anyopaque, label: []const u8) anyerror!bt.Central {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "btCentral")) {
                        return self.btCentral(label);
                    }
                    return error.Unsupported;
                }

                fn btPeripheralFn(ptr: *anyopaque, label: []const u8) anyerror!bt.Peripheral {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "btPeripheral")) {
                        return self.btPeripheral(label);
                    }
                    return error.Unsupported;
                }

                fn micFn(ptr: *anyopaque, label: []const u8) anyerror!Mic {
                    if (comptime !has_audio) return error.Unsupported;

                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "mic")) {
                        return self.mic(label);
                    }
                    return error.Unsupported;
                }

                fn speakerFn(ptr: *anyopaque, label: []const u8) anyerror!Speaker {
                    if (comptime !has_audio) return error.Unsupported;

                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "speaker")) {
                        return self.speaker(label);
                    }
                    return error.Unsupported;
                }

                fn audioSystemFn(ptr: *anyopaque, label: []const u8) anyerror!*AudioSystem {
                    if (comptime !has_audio) return error.Unsupported;

                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    if (comptime @hasDecl(Impl, "audioSystem")) {
                        return self.audioSystem(label);
                    }
                    return error.Unsupported;
                }

                const vtable = VTable{
                    .deinit = deinitFn,
                    .state = stateFn,
                    .powerOn = powerOnFn,
                    .start = startFn,
                    .enterLightSleep = enterLightSleepFn,
                    .enterDeepSleep = enterDeepSleepFn,

                    .singleButton = singleButtonFn,
                    .groupedButton = groupedButtonFn,
                    .imu = imuFn,
                    .ledStrip = ledStripFn,
                    .modem = modemFn,
                    .nfc = nfcFn,
                    .touch = touchFn,
                    .wifiSta = wifiStaFn,
                    .wifiAp = wifiApFn,
                    .btCentral = btCentralFn,
                    .btPeripheral = btPeripheralFn,
                    .mic = micFn,
                    .speaker = speakerFn,
                    .audioSystem = audioSystemFn,
                };
            };

            return .{
                .ptr = @ptrCast(impl),
                .vtable = &gen.vtable,
            };
        }

        pub fn deinit(self: Board) void {
            if (self.vtable.deinit) |f| f(self.ptr);
        }

        pub fn state(self: Board) State {
            if (self.vtable.state) |f| return f(self.ptr);
            return .uninitialized;
        }

        pub fn powerOn(self: Board) !void {
            if (self.vtable.powerOn) |f| return f(self.ptr);
            return error.Unsupported;
        }

        pub fn start(self: Board) !void {
            if (self.vtable.start) |f| return f(self.ptr);
            return error.Unsupported;
        }

        pub fn enterLightSleep(self: Board) !void {
            if (self.vtable.enterLightSleep) |f| return f(self.ptr);
            return error.Unsupported;
        }

        pub fn enterDeepSleep(self: Board) !void {
            if (self.vtable.enterDeepSleep) |f| return f(self.ptr);
            return error.Unsupported;
        }

        pub fn singleButton(self: Board, label: []const u8) !drivers.button.Single {
            if (self.vtable.singleButton) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn groupedButton(self: Board, label: []const u8) !drivers.button.Grouped {
            if (self.vtable.groupedButton) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn imu(self: Board, label: []const u8) !drivers.imu {
            if (self.vtable.imu) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn ledStrip(self: Board, label: []const u8) !ledstrip.LedStrip {
            if (self.vtable.ledStrip) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn modem(self: Board, label: []const u8) !drivers.Modem {
            if (self.vtable.modem) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn nfc(self: Board, label: []const u8) !drivers.nfc.Reader {
            if (self.vtable.nfc) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn touch(self: Board, label: []const u8) !drivers.Touch {
            if (self.vtable.touch) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn wifiSta(self: Board, label: []const u8) !drivers.wifi.Sta {
            if (self.vtable.wifiSta) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn wifiAp(self: Board, label: []const u8) !drivers.wifi.Ap {
            if (self.vtable.wifiAp) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn btCentral(self: Board, label: []const u8) !bt.Central {
            if (self.vtable.btCentral) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn btPeripheral(self: Board, label: []const u8) !bt.Peripheral {
            if (self.vtable.btPeripheral) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn mic(self: Board, label: []const u8) !Mic {
            if (comptime !has_audio) return error.Unsupported;

            if (self.vtable.mic) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn speaker(self: Board, label: []const u8) !Speaker {
            if (comptime !has_audio) return error.Unsupported;

            if (self.vtable.speaker) |f| return f(self.ptr, label);
            return error.Unsupported;
        }

        pub fn audioSystem(self: Board, label: []const u8) !*AudioSystem {
            if (comptime !has_audio) return error.Unsupported;

            if (self.vtable.audioSystem) |f| return f(self.ptr, label);
            return error.Unsupported;
        }
    };
}
