//! stdz — cross-platform runtime library.
//!
//! Usage:
//!   const stdz = @import("stdz").make(platform);
//!
//!   var t = try stdz.Thread.spawn(.{}, myFunc, .{ &state });
//!   t.join();

const root = @This();
const collections = @import("stdz/collections.zig");

pub const ascii = @import("stdz/ascii.zig");
pub const crypto = @import("stdz/crypto.zig");
pub const fmt = @import("stdz/fmt.zig");
pub const heap = @import("stdz/heap.zig");
pub const Io = @import("stdz/Io.zig");
pub const json = @import("stdz/json.zig");
pub const log = @import("stdz/log.zig");
pub const mem = @import("stdz/mem.zig");
pub const posix = @import("stdz/posix.zig");
pub const Random = @import("stdz/Random.zig");
pub const Thread = @import("stdz/Thread.zig");
pub const time = @import("stdz/time.zig");
pub const math = @import("stdz/math.zig");
pub const debug = @import("stdz/debug.zig");
pub const meta = @import("stdz/meta.zig");
pub const atomic = @import("stdz/atomic.zig");
pub const builtin = @import("stdz/builtin.zig");
pub const testing = @import("stdz/testing.zig");

pub const array_list = collections.array_list;
pub const ArrayList = collections.ArrayList;
pub const ArrayListAligned = collections.ArrayListAligned;
pub const ArrayListAlignedUnmanaged = collections.ArrayListAlignedUnmanaged;
pub const ArrayListUnmanaged = collections.ArrayListUnmanaged;

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

pub fn make(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "atomic")) {
            @compileError("stdz.make requires Impl.atomic; std-backed runtimes must re-export embed_std.stdz.atomic");
        }
    }

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
        pub const json = root.json;
        pub const meta = root.meta;
        pub const Io = root.Io;
        pub const debug = root.debug;
        pub const atomic = root.atomic.make(Impl.atomic);
        pub const builtin = root.builtin;
        pub const testing = root.testing.make(Impl.testing);
        pub const Random = root.Random;
        pub const crypto = root.crypto.make(Impl.crypto);
        pub const math = root.math;
        // Platform-independent data structures (from std)
        pub const array_list = collections.array_list;
        pub const ArrayList = collections.ArrayList;
        pub const ArrayListAligned = collections.ArrayListAligned;
        pub const ArrayListAlignedUnmanaged = collections.ArrayListAlignedUnmanaged;
        pub const ArrayListUnmanaged = collections.ArrayListUnmanaged;

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
