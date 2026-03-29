//! Platform-independent data structures — re-exported from std.
//!
//! Every symbol here mirrors its std counterpart exactly so that
//! `embed.ArrayList(u8)` behaves identically to `std.ArrayList(u8)`.

const re_export = struct {
    const std = @import("std");

    // Array lists.
    pub const ArrayList = std.ArrayList;
    pub const ArrayListAligned = std.ArrayListAligned;
    pub const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
    pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
    pub const array_list = std.array_list;
    pub const MultiArrayList = std.MultiArrayList;
    pub const SegmentedList = std.SegmentedList;

    // Hash maps.
    pub const hash_map = std.hash_map;

    // Array hash maps.
    pub const array_hash_map = std.array_hash_map;

    // Buffer-backed maps / sets.
    pub const BufMap = std.BufMap;
    pub const BufSet = std.BufSet;

    // Priority queues.
    pub const PriorityQueue = std.PriorityQueue;
    pub const PriorityDequeue = std.PriorityDequeue;

    // Bit sets.
    pub const bit_set = std.bit_set;

    // Linked lists.
    pub const DoublyLinkedList = std.DoublyLinkedList;
    pub const SinglyLinkedList = std.SinglyLinkedList;

    // Trees.
    pub const Treap = std.Treap;

    // Enum-indexed structures.
    pub const enums = std.enums;

    // Static / comptime maps.
    pub const static_string_map = std.static_string_map;

    // Stacks.
    pub const BitStack = std.BitStack;
};

pub const ArrayHashMap = array_hash_map.ArrayHashMap;
pub const ArrayHashMapUnmanaged = array_hash_map.ArrayHashMapUnmanaged;
pub const ArrayList = re_export.ArrayList;
pub const ArrayListAligned = re_export.ArrayListAligned;
pub const ArrayListAlignedUnmanaged = re_export.ArrayListAlignedUnmanaged;
pub const ArrayListUnmanaged = re_export.ArrayListUnmanaged;
pub const AutoArrayHashMap = array_hash_map.AutoArrayHashMap;
pub const AutoArrayHashMapUnmanaged = array_hash_map.AutoArrayHashMapUnmanaged;
pub const AutoHashMap = hash_map.AutoHashMap;
pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
pub const BitStack = re_export.BitStack;
pub const BufMap = re_export.BufMap;
pub const BufSet = re_export.BufSet;
pub const DoublyLinkedList = re_export.DoublyLinkedList;
pub const DynamicBitSet = bit_set.DynamicBitSet;
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;
pub const EnumArray = enums.EnumArray;
pub const EnumMap = enums.EnumMap;
pub const EnumSet = enums.EnumSet;
pub const HashMap = hash_map.HashMap;
pub const HashMapUnmanaged = hash_map.HashMapUnmanaged;
pub const MultiArrayList = re_export.MultiArrayList;
pub const PriorityDequeue = re_export.PriorityDequeue;
pub const PriorityQueue = re_export.PriorityQueue;
pub const SegmentedList = re_export.SegmentedList;
pub const SinglyLinkedList = re_export.SinglyLinkedList;
pub const StaticBitSet = bit_set.StaticBitSet;
pub const StaticStringMap = static_string_map.StaticStringMap;
pub const StaticStringMapWithEql = static_string_map.StaticStringMapWithEql;
pub const StringArrayHashMap = array_hash_map.StringArrayHashMap;
pub const StringArrayHashMapUnmanaged = array_hash_map.StringArrayHashMapUnmanaged;
pub const StringHashMap = hash_map.StringHashMap;
pub const StringHashMapUnmanaged = hash_map.StringHashMapUnmanaged;
pub const Treap = re_export.Treap;
pub const array_hash_map = re_export.array_hash_map;
pub const array_list = re_export.array_list;
pub const bit_set = re_export.bit_set;
pub const enums = re_export.enums;
pub const hash_map = re_export.hash_map;
pub const static_string_map = re_export.static_string_map;
