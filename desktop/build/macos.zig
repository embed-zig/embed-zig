const std = @import("std");

pub const Sign = union(enum) {
    none,
    ad_hoc,
    identity: []const u8,
};

pub const UsageDescriptions = struct {
    location: ?[]const u8 = null,
    location_when_in_use: ?[]const u8 = null,
};

pub const AppConfig = struct {
    exe: *std.Build.Step.Compile,
    bundle_name: []const u8,
    bundle_identifier: []const u8,
    executable_name: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    development_region: []const u8 = "en",
    info_dictionary_version: []const u8 = "6.0",
    short_version: []const u8 = "0.0.0",
    bundle_version: []const u8 = "0",
    minimum_system_version: ?[]const u8 = null,
    usage_descriptions: UsageDescriptions = .{},
    entitlements: ?std.Build.LazyPath = null,
    sign: Sign = .ad_hoc,
    output_subdir: []const u8 = "app",
};

pub const App = struct {
    step: *std.Build.Step,
    bundle_path: []const u8,
};

pub fn addApp(b: *std.Build, config: AppConfig) App {
    const bundle_path = b.fmt("zig-out/{s}/{s}.app", .{ config.output_subdir, config.bundle_name });
    const executable_name = config.executable_name orelse config.exe.name;
    const display_name = config.display_name orelse config.bundle_name;

    const make_app = b.addSystemCommand(&.{ "/bin/sh", "-c", make_app_script, "desktop-macos-app" });
    make_app.addFileArg(config.exe.getEmittedBin());
    make_app.addArgs(&.{
        bundle_path,
        config.bundle_identifier,
        display_name,
        executable_name,
        config.development_region,
        config.info_dictionary_version,
        config.short_version,
        config.bundle_version,
        config.minimum_system_version orelse "",
        config.usage_descriptions.location orelse "",
        config.usage_descriptions.location_when_in_use orelse "",
    });
    make_app.step.dependOn(&config.exe.step);

    switch (config.sign) {
        .none => return .{
            .step = &make_app.step,
            .bundle_path = bundle_path,
        },
        .ad_hoc, .identity => {
            const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", signIdentity(config.sign) });
            if (config.entitlements) |entitlements| {
                codesign.addArg("--entitlements");
                codesign.addFileArg(entitlements);
            }
            codesign.addArg(bundle_path);
            codesign.step.dependOn(&make_app.step);
            return .{
                .step = &codesign.step,
                .bundle_path = bundle_path,
            };
        },
    }
}

fn signIdentity(sign: Sign) []const u8 {
    return switch (sign) {
        .none => unreachable,
        .ad_hoc => "-",
        .identity => |identity| identity,
    };
}

const make_app_script =
    \\set -eu
    \\exe="$1"
    \\bundle="$2"
    \\bundle_id="$3"
    \\display_name="$4"
    \\exe_name="$5"
    \\development_region="$6"
    \\info_dictionary_version="$7"
    \\short_version="$8"
    \\bundle_version="$9"
    \\minimum_system_version="${10}"
    \\location_usage="${11}"
    \\location_when_in_use_usage="${12}"
    \\plist="$bundle/Contents/Info.plist"
    \\
    \\rm -rf "$bundle"
    \\mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    \\cp "$exe" "$bundle/Contents/MacOS/$exe_name"
    \\chmod +x "$bundle/Contents/MacOS/$exe_name"
    \\
    \\/usr/bin/plutil -create xml1 "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string $development_region" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $exe_name" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string $info_dictionary_version" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleName string $display_name" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $short_version" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $bundle_version" "$plist"
    \\if [ -n "$minimum_system_version" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_system_version" "$plist"
    \\fi
    \\if [ -n "$location_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSLocationUsageDescription string $location_usage" "$plist"
    \\fi
    \\if [ -n "$location_when_in_use_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSLocationWhenInUseUsageDescription string $location_when_in_use_usage" "$plist"
    \\fi
;
