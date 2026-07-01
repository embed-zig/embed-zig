const std = @import("std");
const desktop_build = @import("desktop");

const app_exe_name = "desktop_launcher_app";
const server_exe_name = "desktop_launcher_server";
const bundle_name = "EmbedDesktopLauncher";
const bundle_id = "dev.embed.desktop.launcher";
const location_usage = "Embed desktop uses location permission to let CoreWLAN read WiFi network information.";
const microphone_usage = "Embed desktop uses microphone input for apps that record or monitor audio.";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const port = b.option(u16, "port", "HTTP port for the desktop launcher") orelse 8080;
    const icon = b.option(std.Build.LazyPath, "icon", "macOS .icns icon path for the desktop launcher app bundle");
    const resolved_bundle_name = b.option([]const u8, "desktop_bundle_name", "macOS app bundle name for the desktop launcher") orelse bundle_name;
    const resolved_bundle_id = b.option([]const u8, "desktop_bundle_id", "macOS app bundle identifier for the desktop launcher") orelse bundle_id;
    const resolved_display_name = b.option([]const u8, "desktop_display_name", "macOS display name for the desktop launcher") orelse resolved_bundle_name;
    const resolved_systray_name = b.option([]const u8, "desktop_systray_name", "macOS menu bar name for the desktop launcher") orelse resolved_display_name;
    const storage_root_option = b.option([]const u8, "desktop_storage_root", "Direct host storage root override for the desktop launcher") orelse "";
    const home_dir_option = b.option([]const u8, "desktop_home_dir", "Host home directory used by the desktop platform for Application Support storage") orelse "";
    const run_tray = b.option(bool, "desktop_run_tray", "Run macOS desktop launcher as a menu bar app") orelse true;
    const command_console_desktop_tcp = b.option(
        bool,
        "command_console_desktop_tcp",
        "Enable the command-console app desktop TCP pseudo-serial endpoint",
    ) orelse true;
    const storage_root = normalizeHostPath(b, storage_root_option);
    const home_dir = normalizeHostPath(b, home_dir_option);

    const apps_dep = b.dependency("apps", .{
        .target = target,
        .optimize = optimize,
        .command_console_desktop_tcp = command_console_desktop_tcp,
    });
    const desktop_dep = b.dependency("desktop", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const selected_app = apps_dep.module(app_name);

    const generated_test = createTestSource(b);
    const launcher_config = b.addOptions();
    launcher_config.addOption([]const u8, "app_name", app_name);
    launcher_config.addOption(u16, "port", port);
    launcher_config.addOption([]const u8, "bundle_id", resolved_bundle_id);
    launcher_config.addOption([]const u8, "home_dir", home_dir);
    launcher_config.addOption([]const u8, "storage_root", storage_root);
    launcher_config.addOption(bool, "run_tray", run_tray);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop", .module = desktop_dep.module("desktop") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "lvgl_osal", .module = apps_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
    });
    server_mod.addOptions("desktop_launcher_config", launcher_config);
    if (target.result.os.tag == .macos) {
        server_mod.addCSourceFile(.{
            .file = createStatusAppSource(b),
            .flags = &.{
                "-fobjc-arc",
                b.fmt("-DDESKTOP_LAUNCHER_SYSTRAY_NAME=\"{s}\"", .{resolved_systray_name}),
            },
        });
        server_mod.linkFramework("Cocoa", .{});
    }

    const server_exe = b.addExecutable(.{
        .name = server_exe_name,
        .root_module = server_mod,
    });
    b.installArtifact(server_exe);

    const run_step = b.step("run", "Run the desktop launcher example");
    const build_step = b.step("build", "Build the desktop launcher example");
    switch (target.result.os.tag) {
        .macos => {
            const app_bundle = createAppBundle(
                b,
                server_exe.getEmittedBin(),
                icon,
                resolved_bundle_name,
                resolved_bundle_id,
                resolved_display_name,
            );

            const app_step = b.step("app", "Create a macOS status bar app for the desktop launcher");
            app_step.dependOn(app_bundle.step);

            const run_app = b.addSystemCommand(&.{ "open", "-W", app_bundle.bundle_path });
            if (b.args) |args| {
                run_app.addArg("--args");
                run_app.addArgs(args);
            }
            run_app.step.dependOn(app_bundle.step);

            run_step.dependOn(&run_app.step);
            build_step.dependOn(app_bundle.step);
        },
        else => {
            const unsupported = b.addFail("examples/desktop/launcher currently supports macOS app runs only");
            run_step.dependOn(&unsupported.step);
            build_step.dependOn(&unsupported.step);
        },
    }

    const test_mod = b.createModule(.{
        .root_source_file = generated_test,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop", .module = desktop_dep.module("desktop") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "lvgl_osal", .module = apps_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
    });
    const compile_test = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(compile_test);

    const test_step = b.step("test", "Run the selected app through the desktop launcher test hook");
    test_step.dependOn(&run_test.step);

    b.default_step = build_step;
}

fn createAppBundle(
    b: *std.Build,
    app_exe: std.Build.LazyPath,
    icon: ?std.Build.LazyPath,
    resolved_bundle_name: []const u8,
    resolved_bundle_id: []const u8,
    resolved_display_name: []const u8,
) desktop_build.macos.App {
    return desktop_build.macos.addAppFromPath(b, .{
        .executable = app_exe,
        .bundle_name = resolved_bundle_name,
        .bundle_identifier = resolved_bundle_id,
        .executable_name = app_exe_name,
        .display_name = resolved_display_name,
        .minimum_system_version = "13.0",
        .usage_descriptions = .{
            .location = location_usage,
            .location_when_in_use = location_usage,
            .microphone = microphone_usage,
        },
        .icon = icon,
        .agent = true,
        .sign = .ad_hoc,
    });
}

fn createStatusAppSource(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("desktop_launcher_app.m",
        \\#import <Cocoa/Cocoa.h>
        \\#include <arpa/inet.h>
        \\#include <signal.h>
        \\#include <stdbool.h>
        \\#include <string.h>
        \\#include <sys/socket.h>
        \\#include <unistd.h>
        \\
        \\extern void desktop_launcher_quit(void);
        \\
        \\#ifndef DESKTOP_LAUNCHER_SYSTRAY_NAME
        \\#define DESKTOP_LAUNCHER_SYSTRAY_NAME "Embed"
        \\#endif
        \\
        \\static int launcherPort = 8080;
        \\
        \\static BOOL serverReady(int port) {
        \\    int fd = socket(AF_INET, SOCK_STREAM, 0);
        \\    if (fd < 0) return NO;
        \\
        \\    struct sockaddr_in addr;
        \\    memset(&addr, 0, sizeof(addr));
        \\    addr.sin_family = AF_INET;
        \\    addr.sin_port = htons(port);
        \\    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        \\
        \\    int result = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
        \\    close(fd);
        \\    return result == 0 ? YES : NO;
        \\}
        \\
        \\@interface AppDelegate : NSObject <NSApplicationDelegate>
        \\@property(strong) NSStatusItem *statusItem;
        \\@end
        \\
        \\@implementation AppDelegate
        \\
        \\- (void)applicationDidFinishLaunching:(NSNotification *)notification {
        \\    (void)notification;
        \\    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        \\    [self installStatusItem];
        \\}
        \\
        \\- (void)installStatusItem {
        \\    NSString *systrayName = [NSString stringWithUTF8String:DESKTOP_LAUNCHER_SYSTRAY_NAME];
        \\    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        \\    self.statusItem.button.title = systrayName;
        \\    self.statusItem.button.toolTip = systrayName;
        \\
        \\    NSMenu *menu = [[NSMenu alloc] initWithTitle:systrayName];
        \\    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Browser" action:@selector(openBrowser:) keyEquivalent:@"o"];
        \\    openItem.target = self;
        \\    [menu addItem:openItem];
        \\    [menu addItem:[NSMenuItem separatorItem]];
        \\    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
        \\    quitItem.target = self;
        \\    [menu addItem:quitItem];
        \\    self.statusItem.menu = menu;
        \\}
        \\
        \\- (void)openBrowser:(id)sender {
        \\    (void)sender;
        \\    [self waitForServerAndOpenBrowser];
        \\}
        \\
        \\- (void)waitForServerAndOpenBrowser {
        \\    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        \\        for (int i = 0; i < 100; i++) {
        \\            if (serverReady(launcherPort)) {
        \\                dispatch_async(dispatch_get_main_queue(), ^{
        \\                    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%d/", launcherPort];
        \\                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
        \\                });
        \\                return;
        \\            }
        \\            usleep(100000);
        \\        }
        \\        NSLog(@"desktop server did not become ready on port %d", launcherPort);
        \\    });
        \\}
        \\
        \\- (void)quit:(id)sender {
        \\    (void)sender;
        \\    desktop_launcher_quit();
        \\}
        \\
        \\@end
        \\
        \\void desktop_launcher_run_tray(unsigned int port) {
        \\    launcherPort = (int)port;
        \\    @autoreleasepool {
        \\        NSApplication *app = [NSApplication sharedApplication];
        \\        AppDelegate *delegate = [[AppDelegate alloc] init];
        \\        app.delegate = delegate;
        \\        [app run];
        \\    }
        \\}
        \\
    );
}

fn normalizeHostPath(b: *std.Build, value: []const u8) []const u8 {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return value;
    return b.pathFromRoot(value);
}

fn createTestSource(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("desktop_launcher_test.zig",
        \\const std = @import("std");
        \\const desktop = @import("desktop");
        \\const glib = @import("glib");
        \\const gstd = @import("gstd");
        \\const lvgl_osal = @import("lvgl_osal");
        \\const selected_app = @import("selected_app");
        \\
        \\comptime {
        \\    _ = lvgl_osal.make(gstd.runtime, std.heap.page_allocator);
        \\}
        \\
        \\const PlatformCtx = if (@hasDecl(selected_app, "TestPlatformCtx"))
        \\    selected_app.TestPlatformCtx
        \\else
        \\    desktop.PlatformCtx;
        \\
        \\test "desktop launcher selected app" {
        \\    const Launcher = selected_app.make(PlatformCtx, gstd.runtime);
        \\
        \\    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .desktop_launcher);
        \\    defer t.deinit();
        \\
        \\    t.run("app", Launcher.createTestRunner());
        \\    if (!t.wait()) return error.TestFailed;
        \\}
        \\
    );
}
