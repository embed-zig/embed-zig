const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const nfc_state = @import("state.zig");
const testing_api = @import("testing");

const FoundState = nfc_state.Found;
const ReadState = nfc_state.Read;

pub fn reduceFound(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .nfc_found => |found| {
            store.set(FoundState{
                .source_id = found.source_id,
                .uid_end = found.uid_end,
                .buf = found.buf,
                .card_type = found.card_type,
            });
            return 0;
        },
        else => return 0,
    }
}

pub fn reduceRead(store: anytype, message: Message, emit: Emitter) !usize {
    _ = emit;

    switch (message.body) {
        .nfc_read => |read_event| {
            store.set(ReadState{
                .source_id = read_event.source_id,
                .uid_end = read_event.uid_end,
                .payload_end = read_event.payload_end,
                .buf = read_event.buf,
                .card_type = read_event.card_type,
            });
            return 0;
        },
        else => return 0,
    }
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn reduceFoundUpdatesStore(testing: anytype) !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const FoundStore = StoreObject.make(embed_std.std, FoundState, .nfc_found);
            var store = FoundStore.init(testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try testing.expectEqual(@as(usize, 0), try reduceFound(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_found = .{
                        .source_id = 17,
                        .uid_end = 4,
                        .buf = blk: {
                            var buf = [_]u8{0} ** @import("event.zig").max_uid_len;
                            buf[0] = 0x04;
                            buf[1] = 0xA1;
                            buf[2] = 0xB2;
                            buf[3] = 0xC3;
                            break :blk buf;
                        },
                        .card_type = .ndef,
                    },
                },
            }, Emitter.init(&sink)));

            store.tick();
            const next = store.get();
            try testing.expectEqual(@as(u32, 17), next.source_id);
            try testing.expectEqual(@as(?@import("event.zig").CardType, .ndef), next.card_type);
            try testing.expectEqualSlices(u8, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, next.uid());
        }

        fn reduceReadUpdatesStore(testing: anytype) !void {
            const embed_std = @import("embed_std");
            const StoreObject = @import("../../store/Object.zig");

            const ReadStore = StoreObject.make(embed_std.std, ReadState, .nfc_read);
            var store = ReadStore.init(testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try testing.expectEqual(@as(usize, 0), try reduceRead(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_read = .{
                        .source_id = 17,
                        .uid_end = 4,
                        .payload_end = 8,
                        .buf = blk: {
                            var buf = [_]u8{0} ** @import("event.zig").max_buf_len;
                            buf[0] = 0x04;
                            buf[1] = 0xA1;
                            buf[2] = 0xB2;
                            buf[3] = 0xC3;
                            buf[4] = 0x03;
                            buf[5] = 0x02;
                            buf[6] = 0xD1;
                            buf[7] = 0x01;
                            break :blk buf;
                        },
                        .card_type = .ndef,
                    },
                },
            }, Emitter.init(&sink)));

            store.tick();
            const next = store.get();
            try testing.expectEqual(@as(u32, 17), next.source_id);
            try testing.expectEqual(@as(?@import("event.zig").CardType, .ndef), next.card_type);
            try testing.expectEqualSlices(u8, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, next.uid());
            try testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0xD1, 0x01 }, next.payload());
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
            const testing = lib.testing;

            TestCase.reduceFoundUpdatesStore(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceReadUpdatesStore(testing) catch |err| {
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
