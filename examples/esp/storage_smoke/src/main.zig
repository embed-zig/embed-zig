const esp = @import("esp");

const grt = esp.grt;

const log = grt.std.log.scoped(.storage_smoke);

const File = opaque {};

extern fn esp_example_storage_init_nvs() c_int;
extern fn esp_example_storage_mount_spiffs() c_int;
extern fn esp_example_storage_spiffs_info(total: *usize, used: *usize) c_int;
extern fn esp_example_storage_unmount_spiffs() c_int;

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File;
extern fn fgets(buffer: [*]u8, size: c_int, file: *File) ?[*]u8;
extern fn fclose(file: *File) c_int;

pub export fn zig_esp_main() void {
    mustOk("esp_example_storage_init_nvs", esp_example_storage_init_nvs());
    mustOk("esp_example_storage_mount_spiffs", esp_example_storage_mount_spiffs());
    defer {
        const rc = esp_example_storage_unmount_spiffs();
        if (rc != 0) log.warn("esp_example_storage_unmount_spiffs failed with rc={d}", .{rc});
    }

    var total: usize = 0;
    var used: usize = 0;
    mustOk("esp_example_storage_spiffs_info", esp_example_storage_spiffs_info(&total, &used));
    log.info("spiffs total={d} used={d}", .{ total, used });

    readAsset();
}

fn readAsset() void {
    const file = fopen("/spiffs/hello.txt", "r") orelse {
        log.warn("hello.txt not found", .{});
        return;
    };
    defer _ = fclose(file);

    var line = [_]u8{0} ** 64;
    if (fgets(line[0..].ptr, @intCast(line.len), file)) |_| {
        log.info("read asset: {s}", .{grt.std.mem.sliceTo(line[0..], 0)});
    }
}

fn mustOk(name: []const u8, rc: c_int) void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    @panic("storage platform call failed");
}
