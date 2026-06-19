const glib = @import("glib");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const NfcState = @import("State.zig");

pub fn reduceFound(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .nfc_found => |found| {
            store.invoke(found, struct {
                fn apply(state: *NfcState, event_value: @TypeOf(found)) void {
                    state.source_id = event_value.source_id;
                    state.uid_end = event_value.uid_end;
                    state.payload_end = event_value.uid_end;
                    @memset(state.buf[0..], 0);
                    @memcpy(state.buf[0..event_value.uid_end], event_value.buf[0..event_value.uid_end]);
                    state.card_type = event_value.card_type;
                }
            }.apply);
        },
        else => return,
    }
}

pub fn reduceRead(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .nfc_read => |read_event| {
            store.invoke(read_event, struct {
                fn apply(state: *NfcState, event_value: @TypeOf(read_event)) void {
                    state.source_id = event_value.source_id;
                    state.uid_end = event_value.uid_end;
                    state.payload_end = event_value.payload_end;
                    state.buf = event_value.buf;
                    state.card_type = event_value.card_type;
                }
            }.apply);
        },
        else => return,
    }
}

pub fn reduceLost(store: anytype, message: Message, emit: Emitter) !void {
    _ = emit;

    switch (message.body) {
        .nfc_lost => |lost| {
            store.invoke(lost, struct {
                fn apply(state: *NfcState, event_value: @TypeOf(lost)) void {
                    state.source_id = event_value.source_id;
                    state.uid_end = 0;
                    state.payload_end = 0;
                    @memset(state.buf[0..], 0);
                    state.card_type = null;
                }
            }.apply);
        },
        else => return,
    }
}

pub fn reduce(store: anytype, message: Message, emit: Emitter) !void {
    switch (message.body) {
        .nfc_found => try reduceFound(store, message, emit),
        .nfc_read => try reduceRead(store, message, emit),
        .nfc_lost => try reduceLost(store, message, emit),
        else => return,
    }
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn reduceFoundUpdatesStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const FoundStore = StoreObject.make(grt, NfcState, .nfc);
            var store = FoundStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduceFound(&store, .{
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
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 17), next.source_id);
            try grt.std.testing.expectEqual(@as(?@import("event.zig").CardType, .ndef), next.card_type);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, next.uid());
            try grt.std.testing.expectEqual(@as(usize, 0), next.payload().len);
        }

        fn reduceReadUpdatesStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const ReadStore = StoreObject.make(grt, NfcState, .nfc);
            var store = ReadStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduceRead(&store, .{
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
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 17), next.source_id);
            try grt.std.testing.expectEqual(@as(?@import("event.zig").CardType, .ndef), next.card_type);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, next.uid());
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0xD1, 0x01 }, next.payload());
        }

        fn reduceTracksCombinedState() !void {
            const StoreObject = @import("../../store/Object.zig");

            const NfcStore = StoreObject.make(grt, NfcState, .nfc);
            var store = NfcStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduce(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_found = .{
                        .source_id = 21,
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
            }, Emitter.init(&sink));
            try reduce(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_read = .{
                        .source_id = 21,
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
            }, Emitter.init(&sink));

            store.tick();
            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 21), next.source_id);
            try grt.std.testing.expectEqual(@as(?@import("event.zig").CardType, .ndef), next.card_type);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, next.uid());
            try grt.std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0xD1, 0x01 }, next.payload());
        }

        fn reduceLostClearsStore() !void {
            const StoreObject = @import("../../store/Object.zig");

            const NfcStore = StoreObject.make(grt, NfcState, .nfc);
            var store = NfcStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};

            try reduceRead(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_read = .{
                        .source_id = 21,
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
            }, Emitter.init(&sink));
            store.tick();

            try reduceLost(&store, .{
                .origin = .source,
                .body = .{
                    .nfc_lost = .{
                        .source_id = 21,
                    },
                },
            }, Emitter.init(&sink));
            store.tick();

            const next = store.get();
            try grt.std.testing.expectEqual(@as(u32, 21), next.source_id);
            try grt.std.testing.expect(next.card_type == null);
            try grt.std.testing.expectEqual(@as(usize, 0), next.uid().len);
            try grt.std.testing.expectEqual(@as(usize, 0), next.payload().len);
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

            TestCase.reduceFoundUpdatesStore() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceReadUpdatesStore() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceTracksCombinedState() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reduceLostClearsStore() catch |err| {
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
