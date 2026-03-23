//! Curated std re-exports used by the embed package.
//!
//! Centralizing these imports makes it easy to audit which std namespaces
//! embed depends on internally.

const zig_std = @import("std");

pub const ascii = zig_std.ascii;
pub const array_hash_map = zig_std.array_hash_map;
pub const array_list = zig_std.array_list;
pub const atomic = zig_std.atomic;
pub const bit_set = zig_std.bit_set;
pub const crypto = zig_std.crypto;
pub const debug = zig_std.debug;
pub const enums = zig_std.enums;
pub const fs = zig_std.fs;
pub const fmt = zig_std.fmt;
pub const hash_map = zig_std.hash_map;
pub const Io = zig_std.Io;
pub const math = zig_std.math;
pub const mem = zig_std.mem;
pub const meta = zig_std.meta;
pub const posix = zig_std.posix;
pub const static_string_map = zig_std.static_string_map;
pub const time = zig_std.time;

pub const Treap = zig_std.Treap;
pub const PriorityDequeue = zig_std.PriorityDequeue;
pub const PriorityQueue = zig_std.PriorityQueue;
pub const Random = zig_std.Random;
pub const SegmentedList = zig_std.SegmentedList;
pub const SinglyLinkedList = zig_std.SinglyLinkedList;
pub const MultiArrayList = zig_std.MultiArrayList;
pub const DoublyLinkedList = zig_std.DoublyLinkedList;
pub const BitStack = zig_std.BitStack;
pub const BufMap = zig_std.BufMap;
pub const BufSet = zig_std.BufSet;
