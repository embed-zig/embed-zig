const testing_api = @import("testing");

pub fn make(comptime std: type) type {
    const common = @import("common.zig").make(std);
    const Allocator = std.mem.Allocator;
    const ArrayList = std.ArrayList;
    const mem = std.mem;

    return struct {
        pub const ExtensionError = error{
            BufferTooSmall,
            InvalidExtension,
            ExtensionTooLarge,
            MissingRequiredExtension,
            DuplicateExtension,
            UnsupportedExtension,
            OutOfMemory,
        };

        pub const KeyShareEntry = struct {
            group: common.NamedGroup,
            key_exchange: []const u8,
        };

        pub const Extension = struct {
            ext_type: common.ExtensionType,
            data: []const u8,
        };

        pub const ExtensionBuilder = struct {
            buffer: []u8,
            pos: usize,

            pub fn init(buffer: []u8) ExtensionBuilder {
                return .{ .buffer = buffer, .pos = 0 };
            }

            pub fn addExtension(self: *ExtensionBuilder, ext_type: common.ExtensionType, data: []const u8) ExtensionError!void {
                const needed = 4 + data.len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ext_type), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(data.len), .big);
                self.pos += 2;
                @memcpy(self.buffer[self.pos..][0..data.len], data);
                self.pos += data.len;
            }

            pub fn addServerName(self: *ExtensionBuilder, hostname: []const u8) ExtensionError!void {
                if (hostname.len > 65535 - 3) return error.ExtensionTooLarge;

                const ext_len = 2 + 1 + 2 + hostname.len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.server_name), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(1 + 2 + hostname.len), .big);
                self.pos += 2;
                self.buffer[self.pos] = 0;
                self.pos += 1;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(hostname.len), .big);
                self.pos += 2;
                @memcpy(self.buffer[self.pos..][0..hostname.len], hostname);
                self.pos += hostname.len;
            }

            pub fn addSupportedVersions(self: *ExtensionBuilder, versions: []const common.ProtocolVersion) ExtensionError!void {
                const list_len = versions.len * 2;
                const ext_len = 1 + list_len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.supported_versions), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                self.buffer[self.pos] = @intCast(list_len);
                self.pos += 1;

                for (versions) |version| {
                    mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(version), .big);
                    self.pos += 2;
                }
            }

            pub fn addSelectedVersion(self: *ExtensionBuilder, version: common.ProtocolVersion) ExtensionError!void {
                var payload: [2]u8 = undefined;
                mem.writeInt(u16, &payload, @intFromEnum(version), .big);
                try self.addExtension(.supported_versions, &payload);
            }

            pub fn addEcPointFormats(self: *ExtensionBuilder) ExtensionError!void {
                const needed = 4 + 2;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.ec_point_formats), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], 2, .big);
                self.pos += 2;
                self.buffer[self.pos] = 1;
                self.pos += 1;
                self.buffer[self.pos] = 0;
                self.pos += 1;
            }

            pub fn addSupportedGroups(self: *ExtensionBuilder, groups: []const common.NamedGroup) ExtensionError!void {
                const list_len = groups.len * 2;
                const ext_len = 2 + list_len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.supported_groups), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
                self.pos += 2;

                for (groups) |group| {
                    mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(group), .big);
                    self.pos += 2;
                }
            }

            pub fn addSignatureAlgorithms(self: *ExtensionBuilder, algorithms: []const common.SignatureScheme) ExtensionError!void {
                const list_len = algorithms.len * 2;
                const ext_len = 2 + list_len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.signature_algorithms), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
                self.pos += 2;

                for (algorithms) |alg| {
                    mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(alg), .big);
                    self.pos += 2;
                }
            }

            pub fn addKeyShareClient(self: *ExtensionBuilder, entries: []const KeyShareEntry) ExtensionError!void {
                var list_len: usize = 0;
                for (entries) |entry| list_len += 4 + entry.key_exchange.len;

                const ext_len = 2 + list_len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.key_share), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
                self.pos += 2;

                for (entries) |entry| {
                    mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(entry.group), .big);
                    self.pos += 2;
                    mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(entry.key_exchange.len), .big);
                    self.pos += 2;
                    @memcpy(self.buffer[self.pos..][0..entry.key_exchange.len], entry.key_exchange);
                    self.pos += entry.key_exchange.len;
                }
            }

            pub fn addKeyShareServer(self: *ExtensionBuilder, entry: KeyShareEntry) ExtensionError!void {
                const ext_len = 4 + entry.key_exchange.len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.key_share), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(entry.group), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(entry.key_exchange.len), .big);
                self.pos += 2;
                @memcpy(self.buffer[self.pos..][0..entry.key_exchange.len], entry.key_exchange);
                self.pos += entry.key_exchange.len;
            }

            pub fn addPskKeyExchangeModes(self: *ExtensionBuilder, modes: []const common.PskKeyExchangeMode) ExtensionError!void {
                const ext_len = 1 + modes.len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.psk_key_exchange_modes), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                self.buffer[self.pos] = @intCast(modes.len);
                self.pos += 1;

                for (modes) |mode| {
                    self.buffer[self.pos] = @intFromEnum(mode);
                    self.pos += 1;
                }
            }

            pub fn addAlpn(self: *ExtensionBuilder, protocols: []const []const u8) ExtensionError!void {
                var list_len: usize = 0;
                for (protocols) |protocol| list_len += 1 + protocol.len;

                const ext_len = 2 + list_len;
                const needed = 4 + ext_len;
                if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(common.ExtensionType.application_layer_protocol_negotiation), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
                self.pos += 2;
                mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
                self.pos += 2;

                for (protocols) |protocol| {
                    self.buffer[self.pos] = @intCast(protocol.len);
                    self.pos += 1;
                    @memcpy(self.buffer[self.pos..][0..protocol.len], protocol);
                    self.pos += protocol.len;
                }
            }

            pub fn getData(self: *const ExtensionBuilder) []const u8 {
                return self.buffer[0..self.pos];
            }
        };

        pub fn parseExtensions(data: []const u8, allocator: Allocator) ExtensionError![]Extension {
            var exts = try ArrayList(Extension).initCapacity(allocator, 0);
            errdefer exts.deinit(allocator);

            var pos: usize = 0;
            while (pos < data.len) {
                if (pos + 4 > data.len) return error.InvalidExtension;

                const ext_type: common.ExtensionType = @enumFromInt(mem.readInt(u16, data[pos..][0..2], .big));
                pos += 2;
                const ext_len = mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;

                if (pos + ext_len > data.len) return error.InvalidExtension;

                try exts.append(allocator, .{
                    .ext_type = ext_type,
                    .data = data[pos..][0..ext_len],
                });
                pos += ext_len;
            }

            return exts.toOwnedSlice(allocator);
        }

        pub fn findExtension(exts: []const Extension, ext_type: common.ExtensionType) ?Extension {
            for (exts) |ext| {
                if (ext.ext_type == ext_type) return ext;
            }
            return null;
        }

        pub fn parseServerName(data: []const u8) ExtensionError!?[]const u8 {
            if (data.len < 5) return error.InvalidExtension;

            const list_len = mem.readInt(u16, data[0..2], .big);
            if (@as(usize, list_len) + 2 > data.len) return error.InvalidExtension;

            var pos: usize = 2;
            const end = 2 + list_len;
            while (pos < end) {
                if (pos + 3 > end) return error.InvalidExtension;
                const name_type = data[pos];
                pos += 1;

                const name_len = mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;

                if (pos + name_len > end) return error.InvalidExtension;
                if (name_type == 0) return data[pos..][0..name_len];
                pos += name_len;
            }

            return null;
        }

        pub fn parseSupportedVersion(data: []const u8) ExtensionError!common.ProtocolVersion {
            if (data.len != 2) return error.InvalidExtension;
            return @enumFromInt(mem.readInt(u16, data[0..2], .big));
        }

        pub fn parseKeyShareServer(data: []const u8) ExtensionError!KeyShareEntry {
            if (data.len < 4) return error.InvalidExtension;

            const group: common.NamedGroup = @enumFromInt(mem.readInt(u16, data[0..2], .big));
            const key_len = mem.readInt(u16, data[2..4], .big);
            if (data.len != 4 + key_len) return error.InvalidExtension;

            return .{
                .group = group,
                .key_exchange = data[4..][0..key_len],
            };
        }

        pub fn parseSelectedAlpn(data: []const u8) ExtensionError![]const u8 {
            if (data.len < 3) return error.InvalidExtension;
            const list_len = mem.readInt(u16, data[0..2], .big);
            if (data.len != 2 + list_len or list_len < 2) return error.InvalidExtension;
            const protocol_len = data[2];
            if (protocol_len == 0 or data.len != 3 + protocol_len) return error.InvalidExtension;
            return data[3..][0..protocol_len];
        }

        pub fn findMatchingAlpn(data: []const u8, supported: []const []const u8) ExtensionError!?[]const u8 {
            if (data.len < 2) return error.InvalidExtension;
            const list_len = mem.readInt(u16, data[0..2], .big);
            if (data.len != 2 + list_len) return error.InvalidExtension;

            var pos: usize = 2;
            while (pos < data.len) {
                const protocol_len = data[pos];
                pos += 1;
                if (protocol_len == 0 or pos + protocol_len > data.len) return error.InvalidExtension;
                const protocol = data[pos..][0..protocol_len];
                pos += protocol_len;
                for (supported) |candidate| {
                    if (mem.eql(u8, candidate, protocol)) return candidate;
                }
            }
            return null;
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            const testing = std.testing;
            const common = @import("common.zig").make(std);
            const extensions = make(std);

            {
                var buf: [256]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                try builder.addServerName("test.example.com");

                const exts = try extensions.parseExtensions(builder.getData(), allocator);
                defer allocator.free(exts);

                const sni = extensions.findExtension(exts, .server_name) orelse return error.TestUnexpectedResult;
                const hostname = try extensions.parseServerName(sni.data);
                try testing.expect(hostname != null);
                try testing.expectEqualStrings("test.example.com", hostname.?);
            }

            {
                var buf: [256]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                try builder.addSupportedVersions(&.{ .tls_1_3, .tls_1_2 });

                const data = builder.getData();
                try testing.expect(data.len >= 9);
                try testing.expectEqual(@as(u16, @intFromEnum(common.ExtensionType.supported_versions)), std.mem.readInt(u16, data[0..2], .big));
                try testing.expectEqual(@as(u8, 4), data[4]);
            }

            {
                var buf: [16]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                try builder.addSelectedVersion(.tls_1_3);

                const exts = try extensions.parseExtensions(builder.getData(), allocator);
                defer allocator.free(exts);

                const ext = extensions.findExtension(exts, .supported_versions) orelse return error.TestUnexpectedResult;
                try testing.expectEqual(common.ProtocolVersion.tls_1_3, try extensions.parseSupportedVersion(ext.data));
            }

            {
                var buf: [64]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                const key = [_]u8{0xAA} ** 32;
                try builder.addKeyShareServer(.{
                    .group = .x25519,
                    .key_exchange = &key,
                });

                const exts = try extensions.parseExtensions(builder.getData(), allocator);
                defer allocator.free(exts);

                const ext = extensions.findExtension(exts, .key_share) orelse return error.TestUnexpectedResult;
                const entry = try extensions.parseKeyShareServer(ext.data);
                try testing.expectEqual(common.NamedGroup.x25519, entry.group);
                try testing.expectEqualSlices(u8, &key, entry.key_exchange);
            }

            {
                var buf: [4]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                try testing.expectError(error.BufferTooSmall, builder.addServerName("example.com"));
            }

            try testing.expectError(error.InvalidExtension, extensions.parseExtensions(&.{ 0x00, 0x00, 0x00 }, allocator));
            try testing.expectError(error.InvalidExtension, extensions.parseSupportedVersion(&.{0x03}));
            try testing.expectError(error.InvalidExtension, extensions.parseSupportedVersion(&.{ 0x03, 0x04, 0x00 }));
            try testing.expectError(error.InvalidExtension, extensions.parseKeyShareServer(&.{ 0x00, 0x1d, 0x00 }));
            try testing.expectError(
                error.InvalidExtension,
                extensions.parseKeyShareServer(&.{ 0x00, 0x1d, 0x00, 0x02, 0xaa, 0xbb, 0xcc }),
            );

            {
                var buf: [256]u8 = undefined;
                var builder = extensions.ExtensionBuilder.init(&buf);
                try builder.addAlpn(&.{ "h2", "http/1.1" });

                const exts = try extensions.parseExtensions(builder.getData(), allocator);
                defer allocator.free(exts);

                const alpn = extensions.findExtension(exts, common.ExtensionType.application_layer_protocol_negotiation) orelse return error.TestUnexpectedResult;
                try testing.expectEqualStrings("h2", (try extensions.findMatchingAlpn(alpn.data, &.{"h2"})).?);
            }

            try testing.expectEqualStrings("h2", try extensions.parseSelectedAlpn(&.{ 0x00, 0x03, 0x02, 'h', '2' }));
        }
    }.run);
}
