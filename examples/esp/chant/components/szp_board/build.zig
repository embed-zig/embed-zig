const std = @import("std");
const esp = @import("esp");

const component_root = "components/szp_board";

pub fn addTo(b: *std.Build) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{
        .name = "szp_board",
    });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path(component_root ++ "/idf_component.yml"),
    });
    component.addIncludePath(b.path(component_root ++ "/include"));
    component.addCSourceFiles(.{
        .root = b.path(component_root),
        .files = &.{
            "szp_board.c",
            "szp_storage.c",
            "szp_audio.c",
            "szp_button.c",
            "szp_display.c",
        },
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_ledc");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_lcd");
    component.addRequire("esp_timer");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    component.addRequire("spiffs");
    return component;
}
