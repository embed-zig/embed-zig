const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const SyncState = module.SyncState;
const StreamState = module.StreamState;
const Page = module.Page;
const Packet = module.Packet;
const PageOutResult = module.PageOutResult;
const PacketOutResult = module.PacketOutResult;
const Sync = module.Sync;
const Stream = module.Stream;
const pageVersion = module.pageVersion;
const pageContinued = module.pageContinued;
const pageBos = module.pageBos;
const pageEos = module.pageEos;
const pageGranulePos = module.pageGranulePos;
const pageSerialNo = module.pageSerialNo;
const pagePageNo = module.pagePageNo;
const pagePackets = module.pagePackets;

// ── tests ─────────────────────────────────────────────────────────────────

test "sync state lifecycle" {
    var sync = Sync.init();
    defer sync.deinit();

    sync.reset();
}

test "stream state lifecycle" {
    var stream = Stream.init(12345);
    defer stream.deinit();

    stream.reset();
    stream.resetSerial(67890);
}

test "sync buffer allocation" {
    var sync = Sync.init();
    defer sync.deinit();

    const buf = sync.buffer(4096);
    try std.testing.expect(buf != null);
    try std.testing.expect(buf.?.len == 4096);
}

test "sync pageOut returns need_more_data on empty state" {
    var sync = Sync.init();
    defer sync.deinit();

    var page: Page = undefined;
    const result = sync.pageOut(&page);
    try std.testing.expectEqual(PageOutResult.need_more_data, result);
}

test "stream packetOut returns need_more_data on empty stream" {
    var stream = Stream.init(1);
    defer stream.deinit();

    var packet: Packet = undefined;
    const result = stream.packetOut(&packet);
    try std.testing.expectEqual(PacketOutResult.need_more_data, result);
}
