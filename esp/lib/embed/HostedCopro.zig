const esp = @import("esp");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const Config = struct {
    partition_label: [:0]const u8,
    expected_version: Version,
};

pub extern fn esp_embed_hosted_copro_ensure_ready(
    partition_label: [*:0]const u8,
    expected_major: u32,
    expected_minor: u32,
    expected_patch: u32,
) c_int;

pub fn ensureReady(config: Config) !void {
    const rc = esp_embed_hosted_copro_ensure_ready(
        config.partition_label.ptr,
        config.expected_version.major,
        config.expected_version.minor,
        config.expected_version.patch,
    );
    if (rc == 0) return;
    esp.grt.std.log.scoped(.esp_hosted_copro).err(
        "ensure ready failed rc={d} expected={d}.{d}.{d} partition={s}",
        .{
            rc,
            config.expected_version.major,
            config.expected_version.minor,
            config.expected_version.patch,
            config.partition_label,
        },
    );
    return error.HostedCoproFailed;
}
