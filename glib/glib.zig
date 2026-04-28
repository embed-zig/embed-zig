//! glib — application runtime namespace assembled at comptime.
//!
//! `glib.runtime.make(...)` does not own platform behavior. It binds
//! already-selected platform capabilities into one application-facing
//! namespace.

const stdz_mod = @import("stdz");
const context_mod = @import("context");
const testing_mod = @import("testing");
const time_mod = @import("time");
const tests_mod = @import("lib/tests.zig");

pub const std = struct {
    pub const ascii = stdz_mod.ascii;
    pub const crypto = stdz_mod.crypto;
    pub const fmt = stdz_mod.fmt;
    pub const heap = stdz_mod.heap;
    pub const Io = stdz_mod.Io;
    pub const json = stdz_mod.json;
    pub const log = stdz_mod.log;
    pub const mem = stdz_mod.mem;
    pub const posix = stdz_mod.posix;
    pub const Random = stdz_mod.Random;
    pub const Thread = stdz_mod.Thread;
    pub const time = stdz_mod.time;
    pub const math = stdz_mod.math;
    pub const debug = stdz_mod.debug;
    pub const meta = stdz_mod.meta;
    pub const atomic = stdz_mod.atomic;
    pub const builtin = stdz_mod.builtin;
    pub const testing = stdz_mod.testing;

    pub const array_list = stdz_mod.array_list;
    pub const ArrayList = stdz_mod.ArrayList;
    pub const ArrayListAligned = stdz_mod.ArrayListAligned;
    pub const ArrayListAlignedUnmanaged = stdz_mod.ArrayListAlignedUnmanaged;
    pub const ArrayListUnmanaged = stdz_mod.ArrayListUnmanaged;

    pub const MultiArrayList = stdz_mod.MultiArrayList;
    pub const SegmentedList = stdz_mod.SegmentedList;

    pub const hash_map = stdz_mod.hash_map;
    pub const HashMap = stdz_mod.HashMap;
    pub const HashMapUnmanaged = stdz_mod.HashMapUnmanaged;
    pub const AutoHashMap = stdz_mod.AutoHashMap;
    pub const AutoHashMapUnmanaged = stdz_mod.AutoHashMapUnmanaged;
    pub const StringHashMap = stdz_mod.StringHashMap;
    pub const StringHashMapUnmanaged = stdz_mod.StringHashMapUnmanaged;

    pub const array_hash_map = stdz_mod.array_hash_map;
    pub const ArrayHashMap = stdz_mod.ArrayHashMap;
    pub const ArrayHashMapUnmanaged = stdz_mod.ArrayHashMapUnmanaged;
    pub const AutoArrayHashMap = stdz_mod.AutoArrayHashMap;
    pub const AutoArrayHashMapUnmanaged = stdz_mod.AutoArrayHashMapUnmanaged;
    pub const StringArrayHashMap = stdz_mod.StringArrayHashMap;
    pub const StringArrayHashMapUnmanaged = stdz_mod.StringArrayHashMapUnmanaged;

    pub const BufMap = stdz_mod.BufMap;
    pub const BufSet = stdz_mod.BufSet;

    pub const PriorityQueue = stdz_mod.PriorityQueue;
    pub const PriorityDequeue = stdz_mod.PriorityDequeue;

    pub const bit_set = stdz_mod.bit_set;
    pub const StaticBitSet = stdz_mod.StaticBitSet;
    pub const DynamicBitSet = stdz_mod.DynamicBitSet;
    pub const DynamicBitSetUnmanaged = stdz_mod.DynamicBitSetUnmanaged;

    pub const DoublyLinkedList = stdz_mod.DoublyLinkedList;
    pub const SinglyLinkedList = stdz_mod.SinglyLinkedList;

    pub const Treap = stdz_mod.Treap;

    pub const enums = stdz_mod.enums;
    pub const EnumArray = stdz_mod.EnumArray;
    pub const EnumMap = stdz_mod.EnumMap;
    pub const EnumSet = stdz_mod.EnumSet;

    pub const static_string_map = stdz_mod.static_string_map;
    pub const StaticStringMap = stdz_mod.StaticStringMap;
    pub const StaticStringMapWithEql = stdz_mod.StaticStringMapWithEql;

    pub const BitStack = stdz_mod.BitStack;

    pub fn make(comptime Impl: type) type {
        return stdz_mod.make(Impl);
    }

    pub const test_runner = tests_mod.std;
};
pub const testing = struct {
    pub const T = testing_mod.T;
    pub const TestingAllocator = testing_mod.TestingAllocator;
    pub const CountingAllocator = testing_mod.CountingAllocator;
    pub const LimitAllocator = testing_mod.LimitAllocator;
    pub const TestRunner = testing_mod.TestRunner;

    pub const test_runner = tests_mod.testing;
};
pub const context = struct {
    pub const Context = context_mod.Context;

    pub fn make(comptime lib: type) type {
        return context_mod.make(lib);
    }

    pub const test_runner = tests_mod.context;
};
pub const time = struct {
    pub const duration = time_mod.duration;
    pub const instant = time_mod.instant;

    pub fn make(comptime Impl: type) type {
        return time_mod.make(Impl);
    }

    pub const test_runner = tests_mod.time;
};
pub const sync = @import("sync");
pub const io = @import("io");
pub const mime = @import("mime");
pub const net = @import("net");
pub const crypto = @import("crypto");
pub const runtime = struct {
    const runtime_ns = @This();
    const TypeMarker = struct {};
    pub const Options = struct {
        stdz_impl: type,
        time_impl: type,
        channel_factory: @import("sync").channel.FactoryType,
        net_impl: type,
    };

    pub fn make(comptime options: Options) type {
        const std_ns = @import("stdz").make(options.stdz_impl);
        const time_ns = @import("time").make(options.time_impl);
        const channel_factory = options.channel_factory;
        const net_impl = options.net_impl;

        return struct {
            const runtime_marker: TypeMarker = .{};
            pub const runtime = runtime_ns;
            pub const std = std_ns;
            pub const time = time_ns;
            pub const context = @import("context").make(std_ns);
            pub const sync = struct {
                pub const ChannelFactory = channel_factory;
                pub const Channel = @import("sync").Channel(std_ns, channel_factory);

                pub fn Racer(comptime T: type) type {
                    return @import("sync").Racer(std_ns, T);
                }
            };
            pub const net = @import("net").make(std_ns, net_impl);
        };
    }

    pub fn is(comptime ns: type) bool {
        switch (@typeInfo(ns)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => {},
            else => return false,
        }
        if (!@hasDecl(ns, "runtime_marker")) return false;
        return @TypeOf(ns.runtime_marker) == TypeMarker;
    }
};
