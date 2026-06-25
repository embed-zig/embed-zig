const std = @import("std");

pub const Sign = union(enum) {
    none,
    ad_hoc,
    identity: []const u8,
};

pub const UsageDescriptions = struct {
    location: ?[]const u8 = null,
    location_when_in_use: ?[]const u8 = null,
    microphone: ?[]const u8 = null,
    bluetooth: ?[]const u8 = null,
};

pub const ExtraExecutable = struct {
    source: std.Build.LazyPath,
    executable_name: []const u8,
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
    icon: ?std.Build.LazyPath = null,
    extra_executables: []const ExtraExecutable = &.{},
    agent: bool = false,
    sign: Sign = .ad_hoc,
    output_subdir: []const u8 = "app",
};

pub const AppPathConfig = struct {
    executable: std.Build.LazyPath,
    bundle_name: []const u8,
    bundle_identifier: []const u8,
    executable_name: []const u8,
    display_name: ?[]const u8 = null,
    development_region: []const u8 = "en",
    info_dictionary_version: []const u8 = "6.0",
    short_version: []const u8 = "0.0.0",
    bundle_version: []const u8 = "0",
    minimum_system_version: ?[]const u8 = null,
    usage_descriptions: UsageDescriptions = .{},
    entitlements: ?std.Build.LazyPath = null,
    icon: ?std.Build.LazyPath = null,
    extra_executables: []const ExtraExecutable = &.{},
    agent: bool = false,
    sign: Sign = .ad_hoc,
    output_subdir: []const u8 = "app",
};

pub const App = struct {
    step: *std.Build.Step,
    bundle_path: []const u8,
};

pub fn addApp(b: *std.Build, config: AppConfig) App {
    return addAppFromPath(b, .{
        .executable = config.exe.getEmittedBin(),
        .bundle_name = config.bundle_name,
        .bundle_identifier = config.bundle_identifier,
        .executable_name = config.executable_name orelse config.exe.name,
        .display_name = config.display_name,
        .development_region = config.development_region,
        .info_dictionary_version = config.info_dictionary_version,
        .short_version = config.short_version,
        .bundle_version = config.bundle_version,
        .minimum_system_version = config.minimum_system_version,
        .usage_descriptions = config.usage_descriptions,
        .entitlements = config.entitlements,
        .icon = config.icon,
        .extra_executables = config.extra_executables,
        .agent = config.agent,
        .sign = config.sign,
        .output_subdir = config.output_subdir,
    });
}

pub fn addAppFromPath(b: *std.Build, config: AppPathConfig) App {
    const bundle_path = b.fmt("zig-out/{s}/{s}.app", .{ config.output_subdir, config.bundle_name });
    const display_name = config.display_name orelse config.bundle_name;

    const make_app = b.addSystemCommand(&.{ "/bin/sh", "-c", make_app_script, "desktop-macos-app" });
    make_app.addFileArg(config.executable);
    if (config.icon) |icon| {
        make_app.addFileArg(icon);
    } else {
        make_app.addArg("");
    }
    make_app.addArgs(&.{
        bundle_path,
        config.bundle_identifier,
        display_name,
        config.executable_name,
        config.development_region,
        config.info_dictionary_version,
        config.short_version,
        config.bundle_version,
        config.minimum_system_version orelse "",
        config.usage_descriptions.location orelse "",
        config.usage_descriptions.location_when_in_use orelse "",
        config.usage_descriptions.microphone orelse "",
        config.usage_descriptions.bluetooth orelse "",
        if (config.agent) "true" else "false",
        b.fmt("{d}", .{config.extra_executables.len}),
    });
    for (config.extra_executables) |extra| {
        make_app.addFileArg(extra.source);
        make_app.addArg(extra.executable_name);
    }

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
    \\icon="$2"
    \\bundle="$3"
    \\bundle_id="$4"
    \\display_name="$5"
    \\exe_name="$6"
    \\development_region="$7"
    \\info_dictionary_version="$8"
    \\short_version="$9"
    \\bundle_version="${10}"
    \\minimum_system_version="${11}"
    \\location_usage="${12}"
    \\location_when_in_use_usage="${13}"
    \\microphone_usage="${14}"
    \\bluetooth_usage="${15}"
    \\agent="${16}"
    \\extra_count="${17}"
    \\plist="$bundle/Contents/Info.plist"
    \\icon_name="AppIcon.icns"
    \\
    \\rm -rf "$bundle"
    \\mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    \\cp "$exe" "$bundle/Contents/MacOS/$exe_name"
    \\chmod +x "$bundle/Contents/MacOS/$exe_name"
    \\shift 17
    \\i=0
    \\while [ "$i" -lt "$extra_count" ]; do
    \\  extra_src="$1"
    \\  extra_name="$2"
    \\  cp "$extra_src" "$bundle/Contents/MacOS/$extra_name"
    \\  chmod +x "$bundle/Contents/MacOS/$extra_name"
    \\  shift 2
    \\  i=$((i + 1))
    \\done
    \\if [ -n "$icon" ]; then
    \\  cp "$icon" "$bundle/Contents/Resources/$icon_name"
    \\else
    \\  iconset="$bundle/Contents/Resources/AppIcon.iconset"
    \\  mkdir -p "$iconset"
    \\  for size in 16 32 64 128 256 512 1024; do
    \\    /usr/bin/python3 - "$iconset/icon_${size}x${size}.png" "$size" <<'PY'
    \\import struct
    \\import sys
    \\import zlib
    \\
    \\path = sys.argv[1]
    \\size = int(sys.argv[2])
    \\pixels = bytearray()
    \\for y in range(size):
    \\    row = bytearray([0])
    \\    for x in range(size):
    \\        cx = (x + 0.5) / size
    \\        cy = (y + 0.5) / size
    \\        dx = abs(cx - 0.5)
    \\        dy = abs(cy - 0.5)
    \\        in_mark = (
    \\            0.16 <= cx <= 0.84 and 0.16 <= cy <= 0.84 and
    \\            (dy <= 0.075 or dx <= 0.075 or abs(dx - dy) <= 0.055)
    \\        )
    \\        if in_mark:
    \\            rgba = (247, 250, 252, 255)
    \\        else:
    \\            r = int(20 + 26 * cx)
    \\            g = int(28 + 90 * cy)
    \\            b = int(54 + 110 * (1.0 - cx))
    \\            rgba = (r, g, b, 255)
    \\        row.extend(rgba)
    \\    pixels.extend(row)
    \\
    \\def chunk(kind, data):
    \\    body = kind + data
    \\    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    \\
    \\png = bytearray(bytes([137, 80, 78, 71, 13, 10, 26, 10]))
    \\png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
    \\png.extend(chunk(b"IDAT", zlib.compress(bytes(pixels), 9)))
    \\png.extend(chunk(b"IEND", b""))
    \\with open(path, "wb") as f:
    \\    f.write(png)
    \\PY
    \\  done
    \\  cp "$iconset/icon_32x32.png" "$iconset/icon_16x16@2x.png"
    \\  cp "$iconset/icon_64x64.png" "$iconset/icon_32x32@2x.png"
    \\  cp "$iconset/icon_256x256.png" "$iconset/icon_128x128@2x.png"
    \\  cp "$iconset/icon_512x512.png" "$iconset/icon_256x256@2x.png"
    \\  cp "$iconset/icon_1024x1024.png" "$iconset/icon_512x512@2x.png"
    \\  /usr/bin/iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/$icon_name"
    \\  rm -rf "$iconset"
    \\fi
    \\
    \\/usr/bin/plutil -create xml1 "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string $development_region" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $exe_name" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string $info_dictionary_version" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleName string $display_name" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $icon_name" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $short_version" "$plist"
    \\/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $bundle_version" "$plist"
    \\if [ -n "$minimum_system_version" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_system_version" "$plist"
    \\fi
    \\if [ "$agent" = "true" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist"
    \\fi
    \\if [ -n "$location_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSLocationUsageDescription string $location_usage" "$plist"
    \\fi
    \\if [ -n "$location_when_in_use_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSLocationWhenInUseUsageDescription string $location_when_in_use_usage" "$plist"
    \\fi
    \\if [ -n "$microphone_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string $microphone_usage" "$plist"
    \\fi
    \\if [ -n "$bluetooth_usage" ]; then
    \\  /usr/libexec/PlistBuddy -c "Add :NSBluetoothAlwaysUsageDescription string $bluetooth_usage" "$plist"
    \\fi
;
