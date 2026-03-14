//! Zig bindings for libogg.
//!
//! libogg is a library for reading and writing Ogg bitstreams.
//! This module provides a Zig-friendly interface to the C library.
//!
//! Ogg is a multimedia container format that can multiplex audio, video,
//! and other data streams.

const std = @import("std");
const c = @cImport({
    @cInclude("ogg/ogg.h");
});

pub const SyncState = c.ogg_sync_state;
pub const StreamState = c.ogg_stream_state;
pub const Page = c.ogg_page;
pub const Packet = c.ogg_packet;

pub const PageOutResult = enum {
    page_ready,
    need_more_data,
    sync_lost,
};

pub const PacketOutResult = enum {
    packet_ready,
    need_more_data,
    error_or_hole,
};

pub const Sync = struct {
    state: SyncState,

    const Self = @This();

    pub fn init() Self {
        var self = Self{ .state = undefined };
        _ = c.ogg_sync_init(&self.state);
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = c.ogg_sync_clear(&self.state);
    }

    pub fn reset(self: *Self) void {
        _ = c.ogg_sync_reset(&self.state);
    }

    pub fn buffer(self: *Self, size: usize) ?[]u8 {
        const ptr = c.ogg_sync_buffer(&self.state, @intCast(size));
        if (ptr == null) return null;
        return ptr[0..size];
    }

    pub fn wrote(self: *Self, bytes: usize) !void {
        if (c.ogg_sync_wrote(&self.state, @intCast(bytes)) != 0) {
            return error.SyncWroteFailed;
        }
    }

    pub fn pageOut(self: *Self, page: *Page) PageOutResult {
        const ret = c.ogg_sync_pageout(&self.state, page);
        return switch (ret) {
            1 => .page_ready,
            0 => .need_more_data,
            else => .sync_lost,
        };
    }
};

pub const Stream = struct {
    state: StreamState,

    const Self = @This();

    pub fn init(serial: i32) Self {
        var self = Self{ .state = undefined };
        _ = c.ogg_stream_init(&self.state, serial);
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = c.ogg_stream_clear(&self.state);
    }

    pub fn reset(self: *Self) void {
        _ = c.ogg_stream_reset(&self.state);
    }

    pub fn resetSerial(self: *Self, serial: i32) void {
        _ = c.ogg_stream_reset_serialno(&self.state, serial);
    }

    pub fn pageIn(self: *Self, page: *Page) !void {
        if (c.ogg_stream_pagein(&self.state, page) != 0) {
            return error.PageInFailed;
        }
    }

    pub fn packetOut(self: *Self, packet: *Packet) PacketOutResult {
        const ret = c.ogg_stream_packetout(&self.state, packet);
        return switch (ret) {
            1 => .packet_ready,
            0 => .need_more_data,
            else => .error_or_hole,
        };
    }

    pub fn packetPeek(self: *Self, packet: *Packet) PacketOutResult {
        const ret = c.ogg_stream_packetpeek(&self.state, packet);
        return switch (ret) {
            1 => .packet_ready,
            0 => .need_more_data,
            else => .error_or_hole,
        };
    }

    pub fn packetIn(self: *Self, packet: *Packet) !void {
        if (c.ogg_stream_packetin(&self.state, packet) != 0) {
            return error.PacketInFailed;
        }
    }

    pub fn pageOut(self: *Self, page: *Page) bool {
        return c.ogg_stream_pageout(&self.state, page) != 0;
    }

    pub fn flush(self: *Self, page: *Page) bool {
        return c.ogg_stream_flush(&self.state, page) != 0;
    }
};

// ── page helper functions ─────────────────────────────────────────────────

pub fn pageVersion(page: *const Page) c_int {
    return c.ogg_page_version(@constCast(page));
}

pub fn pageContinued(page: *const Page) bool {
    return c.ogg_page_continued(@constCast(page)) != 0;
}

pub fn pageBos(page: *const Page) bool {
    return c.ogg_page_bos(@constCast(page)) != 0;
}

pub fn pageEos(page: *const Page) bool {
    return c.ogg_page_eos(@constCast(page)) != 0;
}

pub fn pageGranulePos(page: *const Page) i64 {
    return c.ogg_page_granulepos(@constCast(page));
}

pub fn pageSerialNo(page: *const Page) c_int {
    return c.ogg_page_serialno(@constCast(page));
}

pub fn pagePageNo(page: *const Page) c_long {
    return c.ogg_page_pageno(@constCast(page));
}

pub fn pagePackets(page: *const Page) c_int {
    return c.ogg_page_packets(@constCast(page));
}
