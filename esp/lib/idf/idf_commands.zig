const std = @import("std");
const BuildContext = @import("BuildContext.zig");

pub fn reconfigure(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const run = addIdfPyBaseCommand(b, context);
    run.addArg("reconfigure");
    return &run.step;
}

pub fn build(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step {
    const run = addIdfPyBaseCommand(b, context);
    run.addArg("build");
    return &run.step;
}

pub fn flash(
    b: *std.Build,
    context: BuildContext.BuildContext,
    port: ?[]const u8,
) *std.Build.Step {
    const run = addIdfPyBaseCommand(b, context);
    if (port) |resolved_port| {
        run.addArgs(&.{ "-p", resolved_port });
    }
    run.addArg("flash");
    return &run.step;
}

fn addIdfPyBaseCommand(
    b: *std.Build,
    context: BuildContext.BuildContext,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{context.python_executable_path});
    context.applyIdfEnvironment(run);
    run.setCwd(b.path(context.idf_project_cwd));
    run.addArg(context.idf_py_executable_path);
    run.addArgs(&.{ "-B", context.idf_build_arg });
    run.addArg(b.fmt("-DSDKCONFIG={s}", .{context.sdkconfig_idf_arg}));
    run.setEnvironmentVariable("SDKCONFIG", context.sdkconfig_idf_arg);
    return run;
}
