const ReaderMod = @import("sse/Reader.zig");
const WriterMod = @import("sse/Writer.zig");

pub fn make(comptime lib: type) type {
    return struct {
        pub const Event = struct {
            event: ?[]const u8 = null,
            id: ?[]const u8 = null,
            data: ?[]const u8 = null,
            retry: ?u64 = null,

            pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
                if (self.event) |value| allocator.free(value);
                if (self.id) |value| allocator.free(value);
                if (self.data) |value| allocator.free(value);
                self.* = .{};
            }
        };

        pub const Reader = ReaderMod.make(lib, Event);
        pub const Writer = WriterMod.make(lib, Event);
        pub const ReaderTestRunner = ReaderMod.TestRunner;
        pub const WriterTestRunner = WriterMod.TestRunner;
        pub const Handler = *const fn (ptr: *anyopaque, writer: *Writer) anyerror!void;

        pub const Stream = struct {
            ptr: *anyopaque,
            send: Handler,
        };
    };
}
