const Assembler = @import("../../../../Assembler.zig");
const drivers = @import("drivers");

pub fn makeBuiltApp(comptime grt: type) type {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    const AssemblerType = Assembler.make(grt, .{
        .pipeline = .{
            .tick_interval = grt.time.duration.MilliSecond,
        },
    });
    var assembler = AssemblerType.init();
    assembler.addImu(.sensor, 17);
    assembler.setState("io/imu", .{.sensor});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .sensor = drivers.imu,
    };
    return assembler.build(build_config);
}

pub const DummyImuImpl = struct {
    pub fn read(_: *@This()) !drivers.imu.Sample {
        return .{};
    }
};
