//! Platform-independent data structures — re-exported from std.
//!
//! Every symbol here mirrors its std counterpart exactly so that
//! `embed.ArrayList(u8)` behaves identically to `std.ArrayList(u8)`.

const std = @import("std");

// ── Array lists ──────────────────────────────────────────────────────

pub const array_list = std.array_list;

pub fn ArrayList(comptime T: type) type {
    return array_list.Aligned(T, null);
}
pub const ArrayListAligned = array_list.Aligned;
pub const ArrayListAlignedUnmanaged = array_list.Aligned;
pub const ArrayListUnmanaged = ArrayList;

// ── Multi / segmented lists ──────────────────────────────────────────

pub const MultiArrayList = std.MultiArrayList;
pub const SegmentedList = std.SegmentedList;

// ── Hash maps ────────────────────────────────────────────────────────

pub const hash_map = std.hash_map;

pub const HashMap = hash_map.HashMap;
pub const HashMapUnmanaged = hash_map.HashMapUnmanaged;
pub const AutoHashMap = hash_map.AutoHashMap;
pub const AutoHashMapUnmanaged = hash_map.AutoHashMapUnmanaged;
pub const StringHashMap = hash_map.StringHashMap;
pub const StringHashMapUnmanaged = hash_map.StringHashMapUnmanaged;

// ── Array hash maps ─────────────────────────────────────────────────

pub const array_hash_map = std.array_hash_map;

pub const ArrayHashMap = array_hash_map.ArrayHashMap;
pub const ArrayHashMapUnmanaged = array_hash_map.ArrayHashMapUnmanaged;
pub const AutoArrayHashMap = array_hash_map.AutoArrayHashMap;
pub const AutoArrayHashMapUnmanaged = array_hash_map.AutoArrayHashMapUnmanaged;
pub const StringArrayHashMap = array_hash_map.StringArrayHashMap;
pub const StringArrayHashMapUnmanaged = array_hash_map.StringArrayHashMapUnmanaged;

// ── Buffer-backed maps / sets ────────────────────────────────────────

pub const BufMap = std.BufMap;
pub const BufSet = std.BufSet;

// ── Priority queues ──────────────────────────────────────────────────

pub const PriorityQueue = std.PriorityQueue;
pub const PriorityDequeue = std.PriorityDequeue;

// ── Bit sets ─────────────────────────────────────────────────────────

pub const bit_set = std.bit_set;

pub const StaticBitSet = bit_set.StaticBitSet;
pub const DynamicBitSet = bit_set.DynamicBitSet;
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;

// ── Linked lists (intrusive) ─────────────────────────────────────────

pub const DoublyLinkedList = std.DoublyLinkedList;
pub const SinglyLinkedList = std.SinglyLinkedList;

// ── Trees (intrusive) ────────────────────────────────────────────────

pub const Treap = std.Treap;

// ── Enum-indexed structures ──────────────────────────────────────────

pub const enums = std.enums;

pub const EnumArray = enums.EnumArray;
pub const EnumMap = enums.EnumMap;
pub const EnumSet = enums.EnumSet;

// ── Static / comptime maps ───────────────────────────────────────────

pub const static_string_map = std.static_string_map;

pub const StaticStringMap = static_string_map.StaticStringMap;
pub const StaticStringMapWithEql = static_string_map.StaticStringMapWithEql;

// ── Stacks ───────────────────────────────────────────────────────────

pub const BitStack = std.BitStack;
