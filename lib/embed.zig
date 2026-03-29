//! embed — cross-platform runtime library.
//!
//! Usage:
//!   const embed = @import("embed").make(platform);
//!
//!   var t = try embed.Thread.spawn(.{}, myFunc, .{ &state });
//!   t.join();

const root = @This();

pub const ascii = @import("embed/ascii.zig");
pub const collections = @import("embed/collections.zig");
pub const crypto = @import("embed/crypto.zig");
pub const fmt = @import("embed/fmt.zig");
pub const heap = @import("embed/heap.zig");
pub const Io = @import("embed/Io.zig");
pub const log = @import("embed/log.zig");
pub const mem = @import("embed/mem.zig");
pub const posix = @import("embed/posix.zig");
pub const Random = @import("embed/Random.zig");
pub const Thread = @import("embed/Thread.zig");
pub const time = @import("embed/time.zig");
pub const math = @import("embed/math.zig");
pub const debug = @import("embed/debug.zig");
pub const meta = @import("embed/meta.zig");
pub const atomic = @import("embed/atomic.zig");
pub const testing = @import("embed/testing.zig");
pub const test_runner = struct {
    pub const logging = @import("embed/test_runner/logging.zig");
};

pub fn make(comptime Impl: type) type {
    return struct {
        const Self = @This();
        pub const heap = root.heap.make(Impl.heap);
        pub const Thread = root.Thread.make(Impl.Thread, Self.heap);
        pub const log = root.log.make(Impl.log);
        pub const posix = root.posix.make(Impl.posix);
        pub const time = root.time.make(Impl.time);
        pub const ascii = root.ascii;
        pub const mem = root.mem;
        pub const fmt = root.fmt;
        pub const meta = root.meta;
        pub const Io = root.Io;
        pub const debug = root.debug;
        pub const atomic = root.atomic;
        pub const testing = root.testing.make(Impl.testing);
        pub const Random = root.Random;
        pub const crypto = root.crypto.make(Impl.crypto);
        pub const math = root.math;
        // Platform-independent data structures (from std)
        pub const array_list = collections.array_list;
        pub fn ArrayList(comptime T: type) type {
            return collections.ArrayList(T);
        }
        pub const ArrayListAligned = collections.ArrayListAligned;
        pub const ArrayListAlignedUnmanaged = collections.ArrayListAlignedUnmanaged;
        pub const ArrayListUnmanaged = ArrayList;

        pub const MultiArrayList = collections.MultiArrayList;
        pub const SegmentedList = collections.SegmentedList;

        pub const hash_map = collections.hash_map;
        pub const HashMap = collections.HashMap;
        pub const HashMapUnmanaged = collections.HashMapUnmanaged;
        pub const AutoHashMap = collections.AutoHashMap;
        pub const AutoHashMapUnmanaged = collections.AutoHashMapUnmanaged;
        pub const StringHashMap = collections.StringHashMap;
        pub const StringHashMapUnmanaged = collections.StringHashMapUnmanaged;

        pub const array_hash_map = collections.array_hash_map;
        pub const ArrayHashMap = collections.ArrayHashMap;
        pub const ArrayHashMapUnmanaged = collections.ArrayHashMapUnmanaged;
        pub const AutoArrayHashMap = collections.AutoArrayHashMap;
        pub const AutoArrayHashMapUnmanaged = collections.AutoArrayHashMapUnmanaged;
        pub const StringArrayHashMap = collections.StringArrayHashMap;
        pub const StringArrayHashMapUnmanaged = collections.StringArrayHashMapUnmanaged;

        pub const BufMap = collections.BufMap;
        pub const BufSet = collections.BufSet;

        pub const PriorityQueue = collections.PriorityQueue;
        pub const PriorityDequeue = collections.PriorityDequeue;

        pub const bit_set = collections.bit_set;
        pub const StaticBitSet = collections.StaticBitSet;
        pub const DynamicBitSet = collections.DynamicBitSet;
        pub const DynamicBitSetUnmanaged = collections.DynamicBitSetUnmanaged;

        pub const DoublyLinkedList = collections.DoublyLinkedList;
        pub const SinglyLinkedList = collections.SinglyLinkedList;

        pub const Treap = collections.Treap;

        pub const enums = collections.enums;
        pub const EnumArray = collections.EnumArray;
        pub const EnumMap = collections.EnumMap;
        pub const EnumSet = collections.EnumSet;

        pub const static_string_map = collections.static_string_map;
        pub const StaticStringMap = collections.StaticStringMap;
        pub const StaticStringMapWithEql = collections.StaticStringMapWithEql;

        pub const BitStack = collections.BitStack;
    };
}

test "embed/unit_tests" {
    _ = @import("embed/Thread.zig");
    _ = @import("embed/time.zig");
    _ = @import("embed/testing.zig");
}
