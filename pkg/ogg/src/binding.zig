const c = @cImport({
    @cInclude("config.h");
    @cInclude("ogg/ogg.h");
});
const testing_api = @import("testing");

pub const SyncState = c.ogg_sync_state;
pub const StreamState = c.ogg_stream_state;
pub const Page = c.ogg_page;
pub const Packet = c.ogg_packet;

pub const ogg_sync_init = c.ogg_sync_init;
pub const ogg_sync_clear = c.ogg_sync_clear;
pub const ogg_sync_reset = c.ogg_sync_reset;
pub const ogg_sync_buffer = c.ogg_sync_buffer;
pub const ogg_sync_wrote = c.ogg_sync_wrote;
pub const ogg_sync_pageout = c.ogg_sync_pageout;

pub const ogg_stream_init = c.ogg_stream_init;
pub const ogg_stream_clear = c.ogg_stream_clear;
pub const ogg_stream_reset = c.ogg_stream_reset;
pub const ogg_stream_reset_serialno = c.ogg_stream_reset_serialno;
pub const ogg_stream_pagein = c.ogg_stream_pagein;
pub const ogg_stream_packetout = c.ogg_stream_packetout;
pub const ogg_stream_packetpeek = c.ogg_stream_packetpeek;
pub const ogg_stream_packetin = c.ogg_stream_packetin;
pub const ogg_stream_pageout = c.ogg_stream_pageout;
pub const ogg_stream_flush = c.ogg_stream_flush;

pub const ogg_page_version = c.ogg_page_version;
pub const ogg_page_continued = c.ogg_page_continued;
pub const ogg_page_bos = c.ogg_page_bos;
pub const ogg_page_eos = c.ogg_page_eos;
pub const ogg_page_granulepos = c.ogg_page_granulepos;
pub const ogg_page_serialno = c.ogg_page_serialno;
pub const ogg_page_pageno = c.ogg_page_pageno;
pub const ogg_page_packets = c.ogg_page_packets;

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testExportsCoreOggSymbols() !void {
            const testing = lib.testing;

            try testing.expect(@sizeOf(SyncState) > 0);
            try testing.expect(@sizeOf(StreamState) > 0);
            try testing.expect(@sizeOf(Page) > 0);
            try testing.expect(@sizeOf(Packet) > 0);

            _ = ogg_sync_init;
            _ = ogg_stream_init;
            _ = ogg_page_version;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testExportsCoreOggSymbols() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
