//! GATT server — comptime service table, ATT PDU dispatch.
//!
//! Handle assignments and attribute counts resolved at build time.
//! Runtime dispatch matches incoming ATT requests to registered handlers.
//!
//! No I/O — produces ATT response PDUs into caller-provided buffers.

const glib = @import("glib");

const att = @import("../att.zig");

pub const CharProps = struct {
    read: bool = false,
    write: bool = false,
    write_no_rsp: bool = false,
    notify: bool = false,
    indicate: bool = false,

    pub fn toByte(self: CharProps) u8 {
        var v: u8 = 0;
        if (self.read) v |= 0x02;
        if (self.write_no_rsp) v |= 0x04;
        if (self.write) v |= 0x08;
        if (self.notify) v |= 0x10;
        if (self.indicate) v |= 0x20;
        return v;
    }
};

pub const CharDef = struct {
    uuid: u16,
    props: CharProps,
};

pub const ServiceDef = struct {
    uuid: u16,
    chars: []const CharDef,
};

pub fn Service(uuid: u16, chars: []const CharDef) ServiceDef {
    return .{ .uuid = uuid, .chars = chars };
}

pub fn Char(uuid: u16, props: CharProps) CharDef {
    return .{ .uuid = uuid, .props = props };
}

/// Attribute in the flat handle table.
pub const Attribute = struct {
    handle: u16,
    type_uuid: u16,
    value_uuid: u16 = 0,
    props: u8 = 0,
    svc_index: u8 = 0,
    char_index: u8 = 0,
    kind: Kind,

    pub const Kind = enum {
        primary_service,
        characteristic_decl,
        characteristic_value,
        cccd,
    };
};

fn countAttributes(comptime services: []const ServiceDef) usize {
    var count: usize = 0;
    for (services) |svc| {
        count += 1;
        for (svc.chars) |ch| {
            count += 2;
            if (ch.props.notify or ch.props.indicate) count += 1;
        }
    }
    return count;
}

/// Build a flat attribute table from comptime service definitions.
/// Each service produces:
///   1 primary service attribute
///   Per characteristic:
///     1 char declaration
///     1 char value
///     1 CCCD (if notify or indicate)
fn buildAttributeTable(comptime services: []const ServiceDef) [countAttributes(services)]Attribute {
    @setEvalBranchQuota(10000);
    comptime {
        const count = countAttributes(services);
        var table: [count]Attribute = undefined;
        var handle: u16 = 1;
        var idx: usize = 0;

        for (services, 0..) |svc, si| {
            table[idx] = .{
                .handle = handle,
                .type_uuid = att.PRIMARY_SERVICE_UUID,
                .value_uuid = svc.uuid,
                .svc_index = @truncate(si),
                .kind = .primary_service,
            };
            handle += 1;
            idx += 1;

            for (svc.chars, 0..) |ch, ci| {
                table[idx] = .{
                    .handle = handle,
                    .type_uuid = att.CHARACTERISTIC_UUID,
                    .value_uuid = ch.uuid,
                    .props = ch.props.toByte(),
                    .svc_index = @truncate(si),
                    .char_index = @truncate(ci),
                    .kind = .characteristic_decl,
                };
                handle += 1;
                idx += 1;

                table[idx] = .{
                    .handle = handle,
                    .type_uuid = ch.uuid,
                    .value_uuid = ch.uuid,
                    .props = ch.props.toByte(),
                    .svc_index = @truncate(si),
                    .char_index = @truncate(ci),
                    .kind = .characteristic_value,
                };
                handle += 1;
                idx += 1;

                if (ch.props.notify or ch.props.indicate) {
                    table[idx] = .{
                        .handle = handle,
                        .type_uuid = att.CCCD_UUID,
                        .value_uuid = ch.uuid,
                        .svc_index = @truncate(si),
                        .char_index = @truncate(ci),
                        .kind = .cccd,
                    };
                    handle += 1;
                    idx += 1;
                }
            }
        }

        return table;
    }
}

/// Runtime GATT server. Handles ATT PDUs against the comptime attribute table.
pub fn GattServer(comptime services: []const ServiceDef) type {
    const attr_count = countAttributes(services);
    const table: [attr_count]Attribute = comptime buildAttributeTable(services);

    return struct {
        const Self = @This();

        mtu: u16 = att.DEFAULT_MTU,
        handlers: [attr_count]?HandlerFn = .{null} ** attr_count,
        handler_ctxs: [attr_count]?*anyopaque = .{null} ** attr_count,
        cccd_values: [attr_count]u16 = .{0} ** attr_count,

        pub const HandlerFn = *const fn (op: Op, handle: u16, data: []const u8, ctx: ?*anyopaque, out: []u8) usize;

        pub const Op = enum { read, write };

        pub fn init() Self {
            return .{};
        }

        pub fn registerHandler(self: *Self, char_uuid: u16, handler: HandlerFn, ctx: ?*anyopaque) void {
            for (table, 0..) |a, i| {
                if (a.kind == .characteristic_value and a.value_uuid == char_uuid) {
                    self.handlers[i] = handler;
                    self.handler_ctxs[i] = ctx;
                    return;
                }
            }
        }

        /// Process an ATT PDU, write response into out_buf. Returns response length, or 0 for no response.
        pub fn handlePdu(self: *Self, pdu_data: []const u8, out_buf: []u8) usize {
            const pdu = att.decodePdu(pdu_data) orelse return 0;

            return switch (pdu) {
                .exchange_mtu_request => |req| blk: {
                    self.mtu = @max(att.DEFAULT_MTU, @min(req.client_mtu, att.MAX_MTU));
                    const resp = att.encodeMtuResponse(out_buf, self.mtu);
                    break :blk resp.len;
                },
                .read_by_group_type_request => |req| self.handleReadByGroupType(req, out_buf),
                .read_by_type_request => |req| self.handleReadByType(req, out_buf),
                .find_information_request => |req| self.handleFindInformation(req, out_buf),
                .read_request => |req| self.handleRead(req.handle, out_buf),
                .write_request => |req| self.handleWrite(req.handle, req.value, out_buf, true),
                .write_command => |req| blk: {
                    _ = self.handleWrite(req.handle, req.value, out_buf, false);
                    break :blk 0;
                },
                else => 0,
            };
        }

        fn handleReadByGroupType(self: *Self, req: att.ReadByGroupTypeRequest, out: []u8) usize {
            _ = self;
            const req_uuid16 = switch (req.uuid) {
                .uuid16 => |uuid16| uuid16,
                .uuid128 => return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .unsupported_group_type).len,
            };
            if (req_uuid16 != att.PRIMARY_SERVICE_UUID) {
                return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .unsupported_group_type).len;
            }

            var pos: usize = 2; // opcode + length byte
            var entry_len: u8 = 0;
            const max_pos = @min(out.len, att.MAX_PDU_LEN);

            for (table) |a| {
                if (a.handle < req.start_handle or a.handle > req.end_handle) continue;
                if (a.kind != .primary_service) continue;

                const end_handle = getServiceEndHandle(a.svc_index);
                const this_len: u8 = 6; // start(2) + end(2) + uuid16(2)
                if (entry_len == 0) {
                    entry_len = this_len;
                } else if (this_len != entry_len) break;

                if (pos + this_len > max_pos) break;

                glib.std.mem.writeInt(u16, out[pos..][0..2], a.handle, .little);
                glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], end_handle, .little);
                glib.std.mem.writeInt(u16, out[pos + 4 ..][0..2], a.value_uuid, .little);
                pos += this_len;
            }

            if (pos <= 2) {
                return att.encodeErrorResponse(out, att.READ_BY_GROUP_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.READ_BY_GROUP_TYPE_RESPONSE;
            out[1] = entry_len;
            return pos;
        }

        fn handleReadByType(_: *Self, req: att.ReadByTypeRequest, out: []u8) usize {
            const req_uuid16 = switch (req.uuid) {
                .uuid16 => |uuid16| uuid16,
                .uuid128 => return att.encodeErrorResponse(out, att.READ_BY_TYPE_REQUEST, req.start_handle, .attribute_not_found).len,
            };
            var pos: usize = 2;
            var entry_len: u8 = 0;
            const max_pos = @min(out.len, att.MAX_PDU_LEN);

            for (table) |a| {
                if (a.handle < req.start_handle or a.handle > req.end_handle) continue;
                if (a.type_uuid != req_uuid16) continue;

                if (a.kind == .characteristic_decl) {
                    const this_len: u8 = 7; // handle(2) + props(1) + value_handle(2) + uuid(2)
                    if (entry_len == 0) entry_len = this_len;
                    if (pos + this_len > max_pos) break;

                    glib.std.mem.writeInt(u16, out[pos..][0..2], a.handle, .little);
                    out[pos + 2] = a.props;
                    glib.std.mem.writeInt(u16, out[pos + 3 ..][0..2], a.handle + 1, .little);
                    glib.std.mem.writeInt(u16, out[pos + 5 ..][0..2], a.value_uuid, .little);
                    pos += this_len;
                }
            }

            if (pos <= 2) {
                return att.encodeErrorResponse(out, att.READ_BY_TYPE_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.READ_BY_TYPE_RESPONSE;
            out[1] = entry_len;
            return pos;
        }

        fn handleFindInformation(_: *Self, req: att.FindInformationRequest, out: []u8) usize {
            var pos: usize = 2; // opcode + format
            const max_pos = @min(out.len, att.MAX_PDU_LEN);

            for (table) |a| {
                if (a.handle < req.start_handle or a.handle > req.end_handle) continue;
                if (pos + 4 > max_pos) break; // handle(2) + uuid16(2)

                glib.std.mem.writeInt(u16, out[pos..][0..2], a.handle, .little);
                glib.std.mem.writeInt(u16, out[pos + 2 ..][0..2], a.type_uuid, .little);
                pos += 4;
            }

            if (pos <= 2) {
                return att.encodeErrorResponse(out, att.FIND_INFORMATION_REQUEST, req.start_handle, .attribute_not_found).len;
            }

            out[0] = att.FIND_INFORMATION_RESPONSE;
            out[1] = 0x01; // format: 16-bit UUIDs
            return pos;
        }

        fn handleRead(self: *Self, handle: u16, out: []u8) usize {
            for (table, 0..) |a, i| {
                if (a.handle != handle) continue;

                return switch (a.kind) {
                    .primary_service => blk: {
                        out[0] = att.READ_RESPONSE;
                        glib.std.mem.writeInt(u16, out[1..3], a.value_uuid, .little);
                        break :blk 3;
                    },
                    .characteristic_decl => blk: {
                        out[0] = att.READ_RESPONSE;
                        out[1] = a.props;
                        glib.std.mem.writeInt(u16, out[2..4], a.handle + 1, .little);
                        glib.std.mem.writeInt(u16, out[4..6], a.value_uuid, .little);
                        break :blk 6;
                    },
                    .characteristic_value => blk: {
                        if (self.handlers[i]) |handler| {
                            out[0] = att.READ_RESPONSE;
                            const n = handler(.read, handle, &.{}, self.handler_ctxs[i], out[1..]);
                            break :blk 1 + n;
                        }
                        break :blk att.encodeErrorResponse(out, att.READ_REQUEST, handle, .read_not_permitted).len;
                    },
                    .cccd => blk: {
                        out[0] = att.READ_RESPONSE;
                        glib.std.mem.writeInt(u16, out[1..3], self.cccd_values[i], .little);
                        break :blk 3;
                    },
                };
            }
            return att.encodeErrorResponse(out, att.READ_REQUEST, handle, .invalid_handle).len;
        }

        fn handleWrite(self: *Self, handle: u16, value: []const u8, out: []u8, needs_response: bool) usize {
            for (table, 0..) |a, i| {
                if (a.handle != handle) continue;

                switch (a.kind) {
                    .characteristic_value => {
                        if (self.handlers[i]) |handler| {
                            _ = handler(.write, handle, value, self.handler_ctxs[i], out[1..]);
                            if (needs_response) return att.encodeWriteResponse(out).len;
                            return 0;
                        }
                        if (needs_response) return att.encodeErrorResponse(out, att.WRITE_REQUEST, handle, .write_not_permitted).len;
                        return 0;
                    },
                    .cccd => {
                        if (value.len >= 2) {
                            self.cccd_values[i] = glib.std.mem.readInt(u16, value[0..2], .little);
                        }
                        if (needs_response) return att.encodeWriteResponse(out).len;
                        return 0;
                    },
                    else => {},
                }
            }
            if (needs_response) return att.encodeErrorResponse(out, att.WRITE_REQUEST, handle, .invalid_handle).len;
            return 0;
        }

        fn getServiceEndHandle(svc_index: u8) u16 {
            var last: u16 = 0;
            for (table) |a| {
                if (a.svc_index == svc_index) last = a.handle;
            }
            return last;
        }

        pub fn getAttributeTable() []const Attribute {
            return &table;
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const services = comptime &[_]ServiceDef{
                Service(0x180D, &[_]CharDef{
                    Char(0x2A37, .{ .read = true, .notify = true }),
                    Char(0x2A38, .{ .read = true }),
                }),
            };
            const table = comptime buildAttributeTable(services);

            try grt.std.testing.expectEqual(@as(usize, 6), table.len);
            try grt.std.testing.expectEqual(@as(u16, 1), table[0].handle);
            try grt.std.testing.expectEqual(Attribute.Kind.primary_service, table[0].kind);
            try grt.std.testing.expectEqual(@as(u16, 0x180D), table[0].value_uuid);
            try grt.std.testing.expectEqual(Attribute.Kind.characteristic_decl, table[1].kind);
            try grt.std.testing.expectEqual(Attribute.Kind.characteristic_value, table[2].kind);
            try grt.std.testing.expectEqual(@as(u16, 0x2A37), table[2].value_uuid);
            try grt.std.testing.expectEqual(Attribute.Kind.cccd, table[3].kind);
            try grt.std.testing.expectEqual(Attribute.Kind.characteristic_decl, table[4].kind);
            try grt.std.testing.expectEqual(Attribute.Kind.characteristic_value, table[5].kind);
            try grt.std.testing.expectEqual(@as(u16, 0x2A38), table[5].value_uuid);

            {
                const Server = GattServer(&[_]ServiceDef{
                    Service(0x180D, &[_]CharDef{
                        Char(0x2A37, .{ .read = true }),
                    }),
                });
                var server = Server.init();
                var out: [att.MAX_PDU_LEN]u8 = undefined;

                var req_buf: [3]u8 = undefined;
                const req = att.encodeMtuRequest(&req_buf, 256);
                const resp_len = server.handlePdu(req, &out);
                try grt.std.testing.expect(resp_len > 0);
                try grt.std.testing.expectEqual(att.EXCHANGE_MTU_RESPONSE, out[0]);
            }

            {
                const Server = GattServer(&[_]ServiceDef{
                    Service(0x180D, &[_]CharDef{
                        Char(0x2A37, .{ .read = true }),
                    }),
                });
                var server = Server.init();
                var out: [att.MAX_PDU_LEN]u8 = undefined;

                var req_buf: [7]u8 = undefined;
                const req = att.encodeReadByGroupTypeRequest(&req_buf, 0x0001, 0xFFFF, att.UUID.from16(att.PRIMARY_SERVICE_UUID));
                const resp_len = server.handlePdu(req, &out);
                try grt.std.testing.expect(resp_len > 2);
                try grt.std.testing.expectEqual(att.READ_BY_GROUP_TYPE_RESPONSE, out[0]);
            }

            {
                const Server = GattServer(&[_]ServiceDef{
                    Service(0x180D, &[_]CharDef{
                        Char(0x2A37, .{ .read = true }),
                    }),
                });
                var server = Server.init();
                var out: [att.MAX_PDU_LEN]u8 = undefined;

                var req_buf: [21]u8 = undefined;
                const req = att.encodeReadByGroupTypeRequest(&req_buf, 0x0001, 0xFFFF, att.UUID.from128([_]u8{0} ** 16));
                const resp_len = server.handlePdu(req, &out);
                const pdu = att.decodePdu(out[0..resp_len]) orelse return error.DecodeFailed;
                switch (pdu) {
                    .error_response => |err_resp| try grt.std.testing.expectEqual(att.ErrorCode.unsupported_group_type, err_resp.error_code),
                    else => return error.WrongVariant,
                }
            }

            {
                const Server = GattServer(&[_]ServiceDef{
                    Service(0x180D, &[_]CharDef{
                        Char(0x2A37, .{ .read = true }),
                    }),
                });
                var server = Server.init();
                var out: [att.MAX_PDU_LEN]u8 = undefined;

                var req_buf: [21]u8 = undefined;
                const req = att.encodeReadByTypeRequest(&req_buf, 0x0001, 0xFFFF, att.UUID.from128([_]u8{0} ** 16));
                const resp_len = server.handlePdu(req, &out);
                const pdu = att.decodePdu(out[0..resp_len]) orelse return error.DecodeFailed;
                switch (pdu) {
                    .error_response => |err_resp| try grt.std.testing.expectEqual(att.ErrorCode.attribute_not_found, err_resp.error_code),
                    else => return error.WrongVariant,
                }
            }

            {
                const client_mod = @import("client.zig");
                const Server = GattServer(&[_]ServiceDef{
                    Service(0x180D, &[_]CharDef{
                        Char(0x2A37, .{ .read = true, .notify = true }),
                    }),
                });
                var server = Server.init();

                var req_buf: [att.MAX_PDU_LEN]u8 = undefined;
                var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;

                const req = client_mod.encodeDiscoverServices(&req_buf, 0x0001);
                const resp_len = server.handlePdu(req, &resp_buf);
                try grt.std.testing.expect(resp_len > 0);

                var services_out: [4]client_mod.DiscoveredService = undefined;
                const count = client_mod.parseDiscoverServicesResponse(resp_buf[0..resp_len], &services_out);
                try grt.std.testing.expectEqual(@as(usize, 1), count);
                try grt.std.testing.expectEqual(@as(u16, 0x180D), services_out[0].uuid);
            }
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
