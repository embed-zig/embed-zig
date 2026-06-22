const glib = @import("glib");

const common = @import("zux_chant_common");

const component_spec = @embedFile("spec/component_virtual.json");

pub const TestPlatformCtx = common.TestPlatformCtx;
pub const RuntimeSpecType = common.runtimeSpecType(component_spec);
pub const SpecType = common.specType(component_spec);

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return common.make(component_spec, "chant", platform_ctx, platform_grt);
}

pub fn testRunner(comptime platform_ctx: type, comptime platform_grt: type) glib.testing.TestRunner {
    return common.testRunner(component_spec, platform_ctx, platform_grt);
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    return common.run(component_spec, "chant", "chant/stories", platform_ctx, platform_grt);
}
